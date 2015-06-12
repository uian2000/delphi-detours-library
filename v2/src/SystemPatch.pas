unit SystemPatch;

interface

type
  PPMonitor = ^PMonitor;
  PMonitor = ^TMonitor;
  TMonitor = record
  strict private
    type
      PWaitingThread = ^TWaitingThread;
      TWaitingThread = record
        Next: PWaitingThread;
        Thread: TThreadID;
        WaitEvent: Pointer;
      end;
      { TSpinWait implements an exponential backoff algorithm for TSpinLock. The algorithm is as follows:
        If the CPUCount > 1, then the first 10 (YieldThreshold) spin cycles (calls to SpinCycle) will use a base 2
        exponentially increasing spin count starting at 4. After 10 cycles, then the behavior reverts to the same
        behavior as when CPUCount = 1.
        If the CPUCount = 1, then it will sleep 1ms every modulus 20 cycles and sleep 0ms every modulus 5 cycles.
        All other cycles simply yield (SwitchToThread - Windows, sched_yield - POSIX). }
      TSpinWait = record
      private const
        YieldThreshold = 10;
        Sleep1Threshold = 20;
        Sleep0Threshold = 5;
      private
        FCount: Integer;
      public
        procedure Reset; inline;
        procedure SpinCycle;
      end;
      { TSpinLock implements a very simple non-reentrant lock. This lock does not block the calling thread using a
        synchronization object. Instead it opts to burn a few extra CPU cycles using the above TSpinWait type. This
        is typically far faster than fully blocking since the length of time the lock is held is relatively few
        cycles and the thread switching overhead will usually far outpace the few cycles burned by simply spin
        waiting. }
      TSpinLock = record
      private
        FLock: Integer;
      public
        procedure Enter;
        procedure Exit;
      end;
    var
      FLockCount: Integer;
      FRecursionCount: Integer;
      FOwningThread: TThreadID;
      FLockEvent: Pointer;
      FSpinCount: Integer;
      FWaitQueue: PWaitingThread;
      FQueueLock: TSpinLock;
    class var CacheLineSize: Integer;
    class procedure Spin(Iterations: Integer); static;
    class function GetCacheLineSize: Integer; static;
    procedure QueueWaiter(var WaitingThread: TWaitingThread);
    procedure RemoveWaiter(var WaitingThread: TWaitingThread);
    function DequeueWaiter: PWaitingThread;
    function GetEvent: Pointer;
    function CheckOwningThread: TThreadID;
    class procedure CheckMonitorSupport; static; inline;
    class function Create: PMonitor; static;
    // Make sure the following Destroy overload is always
    // listed first since it is called from an asm block
    // and there is no overload-resolution done from an
    // basm symbol reference
  private
    class procedure Destroy(AObject: TObject); overload; static;
  strict private
    class function GetFieldAddress(AObject: TObject): PPMonitor; inline; static;
    class function GetMonitor(AObject: TObject): PMonitor; static;
    procedure Destroy; overload;
    function Enter(Timeout: Cardinal): Boolean; overload;
    procedure Exit; overload;
    function TryEnter: Boolean; overload;
    function Wait(ALock: PMonitor; Timeout: Cardinal): Boolean; overload;
    procedure Pulse; overload;
    procedure PulseAll; overload;
  public
    { In multi-core/multi-processor systems, it is sometimes desirable to spin for a few cycles instead of blocking
      the current thread when attempting to Enter the monitor. Use SetSpinCount to set a reasonable number of times to
      spin before fully blocking the thread. This value usually obtained through empirical study of the particular
      situation.  }
    class procedure SetSpinCount(AObject: TObject; ASpinCount: Integer); static;
    { Enter locks the monitor object with an optional timeout (in ms) value. Enter without a timeout will wait until
      the lock is obtained. If the procedure returns it can be assumed that the lock was acquired. Enter with a
      timeout will return a boolean status indicating whether or not the lock was obtained (True) or the attempt timed
      out prior to acquire the lock (False). Calling Enter with an INFINITE timeout is the same as calling Enter
      without a timeout.
      TryEnter will simply attempt to obtain the lock and return immediately whether or not the lock was acuired.
      Enter with a 0ms timeout is functionally equivalent to TryEnter.
      Exit will potentially release the lock acquired by a call to Enter or TryEnter. Since Enter/TryEnter are
      rentrant, you must balance each of those calls with a corresponding call to Exit. Only the last call to Exit will
      release the lock and allow other threads to obtain it. Runtime error, reMonitorNoLocked, is generated if Exit is
      called and the calling thread does not own the lock. }
    class procedure Enter(AObject: TObject); overload; static; inline;
    class function Enter(AObject: TObject; Timeout: Cardinal): Boolean; overload; static;
    class procedure Exit(AObject: TObject); overload; static;
    class function TryEnter(AObject: TObject): Boolean; overload; static;
    { Wait will atomically fully release the lock (regardless of the recursion count) and block the calling thread
      until another thread calls Pulse or PulseAll. The first overloaded Wait function will assume the locked object
      and wait object are the same and thus the calling thread must own the lock. The second Wait allows the given
      monitor to atomically unlock the separate monitor lock object and block with the calling thread on the first
      given wait object. Wait will not return (even if it times out) until the monitor lock can be acquired again. It
      is possible for wait to return False (the timeout expired) after a much longer period of time has elapsed if
      the locking object was being held by another thread for an extended period. When Wait returns the recursion
      level of the lock has been restored.
      Pulse must be called on the exact same instance passed to Wait in order to properly release one waiting thread.
      PulseAll works the same as Pulse except that it will release all currently waiting threads.
      Wait/Pulse/PulseAll are the same as a traditional condition variable.
    }
    class function Wait(AObject: TObject; Timeout: Cardinal): Boolean; overload; static;
    class function Wait(AObject, ALock: TObject; Timeout: Cardinal): Boolean; overload; static;
    class procedure Pulse(AObject: TObject); overload; static;
    class procedure PulseAll(AObject: TObject); overload; static;
  end;

const
  INFINITE = Cardinal($FFFFFFFF);       {$EXTERNALSYM INFINITE}

implementation

{ TMonitor }

{$IFDEF POSIX}
procedure Sleep(Timeout: Integer); inline;
begin
  usleep(Timeout * 1000);
end;

function GetTickCount: Cardinal; inline;
{$IFDEF LINUX}
var
  t: tms;
begin
  Result := Cardinal(Int64(Cardinal(times(t)) * 1000) div sysconf(_SC_CLK_TCK));
end;
{$ENDIF}
{$IFDEF MACOS}
begin
  Result := AbsoluteToNanoseconds(UpTime) div 1000000;
end;
{$ENDIF MACOS}

{$ENDIF POSIX}

{ TMonitor.TSpinWait }

procedure TMonitor.TSpinWait.Reset;
begin
  FCount := 0;
end;

procedure TMonitor.TSpinWait.SpinCycle;
var
  SpinCount: Integer;
begin
  if (FCount > YieldThreshold) or (CPUCount <= 1) then
  begin
    if FCount >= YieldThreshold then
      SpinCount := FCount - 10
    else
      SpinCount := FCount;
    if SpinCount mod Sleep1Threshold = Sleep1Threshold - 1 then
      Sleep(1)
    else if SpinCount mod Sleep0Threshold = Sleep0Threshold - 1 then
      Sleep(0)
    else
{$IFDEF MSWINDOWS}
      Yield;
{$ENDIF MSWINDOWS}
{$IFDEF POSIX}
      sched_yield;
{$ENDIF POSIX}
  end else
    Spin(4 shl FCount);
  Inc(FCount);
  if FCount < 0 then
    FCount := 10;
end;

{ TMonitor.TSpinLock }

procedure TMonitor.TSpinLock.Enter;
var
  LLock: Integer;
  Wait: TSpinWait;
begin
  Wait.Reset;
  while True do
  begin
    LLock := FLock;
    if LLock = 0 then
    begin
      if InterlockedCompareExchange(FLock, 1, LLock) = LLock then
        System.Exit;
    end;
    Wait.SpinCycle;
  end;
end;

procedure TMonitor.TSpinLock.Exit;
begin
  InterlockedExchange(FLock, 0);
end;

class procedure TMonitor.Spin(Iterations: Integer);
{$IF defined(CPUX86) or defined(CPUX64)}
asm
    CMP  Iterations, 0
    JNG  @Done
@Loop:
    PAUSE
    DEC  Iterations
    CMP  Iterations, 0
    JG   @LOOP
@Done:
end;
{$ELSE}
begin
  while Iterations > 0 do
  begin
    YieldProcessor;
    Dec(Iterations);
  end;
end;
{$IFEND}

class function TMonitor.GetCacheLineSize: Integer;
{$IFDEF MSWINDOWS}
{$POINTERMATH ON}
var
  ProcInfo, CurInfo: PSystemLogicalProcessorInformation;
  Len: DWORD;
begin
  Len := 0;
  if (GetProcAddress(GetModuleHandle(kernel), 'GetLogicalProcessorInformation') <> nil) and
    not GetLogicalProcessorInformation(nil, Len) and (GetLastError = ERROR_INSUFFICIENT_BUFFER) then
  begin
    GetMem(ProcInfo, Len);
    try
      GetLogicalProcessorInformation(ProcInfo, Len);
      CurInfo := ProcInfo;
      while Len > 0 do
      begin
        if (CurInfo.Relationship = RelationCache) and (CurInfo.Cache.Level = 1) then
          System.Exit(CurInfo.Cache.LineSize);
        Inc(CurInfo);
        Dec(Len, SizeOf(CurInfo^));
      end;
    finally
      FreeMem(ProcInfo);
    end;
  end;
  Result := 64; // Use a reasonable default cache line size.
end;
{$POINTERMATH OFF}
{$ENDIF}
{$IFDEF POSIX}
var
  LineSize: UInt64;
  Size: Integer;
begin
  Size := SizeOf(LineSize);
  if sysctlbyname('hw.cachelinesize', @LineSize, @Size, nil, 0) = 0 then
    Result := LineSize
  else
    Result := 64;
end;
{$ENDIF}

class procedure TMonitor.CheckMonitorSupport;
begin
  if MonitorSupport = nil then
    Error(reNoMonitorSupport);
end;

function TMonitor.CheckOwningThread: TThreadID;
begin
  Result := FOwningThread;
  if Result <> GetCurrentThreadId then
    Error(reMonitorNotLocked)
end;

class function TMonitor.Create: PMonitor;
begin
  if CacheLineSize = 0 then
    InterlockedExchange(CacheLineSize, GetCacheLineSize);
  if CacheLineSize > SizeOf(Result^) then
    Result := AllocMem(CacheLineSize)
  else
    Result := AllocMem(SizeOf(Result^));
end;

class procedure TMonitor.Destroy(AObject: TObject);
var
  MonitorFld: PPMonitor;
  Monitor: PMonitor;
begin
  MonitorFld := GetFieldAddress(AObject);
  if MonitorFld^ <> nil then
  begin
    Monitor := MonitorFld^;
    MonitorFld^ := nil;
    Monitor.Destroy;
  end;
end;

procedure TMonitor.Destroy;
begin
  if (MonitorSupport <> nil) and (FLockEvent <> nil) then
    MonitorSupport.FreeSyncObject(FLockEvent);
  FreeMem(@Self);
end;

class procedure TMonitor.Enter(AObject: TObject);
begin
  CheckMonitorSupport;
  GetMonitor(AObject).Enter(INFINITE);
end;

class function TMonitor.Enter(AObject: TObject; Timeout: Cardinal): Boolean;
begin
  CheckMonitorSupport;
  Result := GetMonitor(AObject).Enter(Timeout);
end;

function TMonitor.DequeueWaiter: PWaitingThread;
begin
  FQueueLock.Enter;
  try
    Result := FWaitQueue;
    if (Result = nil) or (Result.Next = Result) then
    begin
      FWaitQueue := nil;
      System.Exit;
    end else
    begin
      Result := FWaitQueue.Next;
      FWaitQueue.Next := FWaitQueue.Next.Next;
    end;
  finally
    FQueueLock.Exit;
  end;
end;

function TMonitor.Enter(Timeout: Cardinal): Boolean;
label
  TryAgain;
var
  Done: Boolean;
  LockCount: Integer;
  StartCount, EndCount: Cardinal;
  SpinCount: Integer;
begin
  SpinCount := FSpinCount;
// Return here if signaled and lock wasn't acquired
TryAgain:
  Result := TryEnter;
  if not Result and (Timeout <> 0) then
  begin
    Done := False;
    // Get the spin count
    if SpinCount > 0 then
    begin
      StartCount := GetTickCount;
      while SpinCount > 0 do
      begin
        if (Timeout <> INFINITE) and ((GetTickCount - StartCount) >= Timeout) then
        begin
          Result := False;
          System.Exit;
        end;
        // if there are already waiters, don't bother spinning
        if FLockCount > 1 then
          Break;
        // Try to get the lock
        if FLockCount = 0 then
          if InterlockedCompareExchange(FLockCount, 1, 0) = 0 then
          begin
            FOwningThread := GetCurrentThreadId;
            FRecursionCount := 1;
            Result := True;
            System.Exit;
          end;
        YieldProcessor;
        Dec(SpinCount);
        // Keep trying until the spin count expires
      end;
      // Adjust the timeout in case the spin-lock expired above.
      if Timeout <> INFINITE then
      begin
        EndCount := GetTickCount;
        if EndCount - StartCount >= Timeout then
        begin
          Result := False;
          System.Exit;
        end;
        Dec(Timeout, EndCount - StartCount);
      end;
    end;
    // Before we can block, we add our count to the lock
    while True do
    begin
      LockCount := FLockCount;
      if LockCount = 0 then
        goto TryAgain;
      if InterlockedCompareExchange(FLockCount, LockCount + 2, LockCount) = LockCount then
        Break;
    end;
    while True do
    begin
      StartCount := GetTickCount;
      // We're not the owner, so blocking is needed
      // GetEvent does a "safe" allocation of the Event
      Result := MonitorSupport.WaitOrSignalObject(nil, GetEvent, Timeout) = WAIT_OBJECT_0;
      if Timeout <> INFINITE then
      begin
        EndCount := GetTickCount;
        if EndCount - StartCount < Timeout then
          Dec(Timeout, EndCount - StartCount)
        else
          Timeout := 0;
      end;
      if Result then
      begin
        // Event was signaled, so try to acquire the lock since this could be a spurious condition
        while True do
        begin
          LockCount := FLockCount;
          if LockCount and 1 <> 0 then
            Break;
          if InterlockedCompareExchange(FLockCount, (LockCount - 2) or 1, LockCount) = LockCount then
          begin
            Done := True;
            Break;
          end;
        end;
      end else
      begin
        // We timed out, remove our presence from the lock count
        repeat
          LockCount := FLockCount;
        until InterlockedCompareExchange(FLockCount, LockCount - 2, LockCount) = LockCount;
        Done := True;
      end;
      if Done then
        Break;
    end;
    if Result then
    begin
      FOwningThread := GetCurrentThreadId;
      FRecursionCount := 1;
    end;
  end;
end;

procedure TMonitor.Exit;
var
  LockCount: Integer;
begin
  CheckOwningThread;
  Dec(FRecursionCount);
  if FRecursionCount = 0 then
  begin
    FOwningThread := 0;
    while True do
    begin
      LockCount := FLockCount;
      if InterlockedCompareExchange(FLockCount, LockCount - 1, LockCount) = LockCount then
      begin
        // if LockCount is <> 0 after we dropped our lock, there were waiters, so signal them
        if LockCount and not 1 <> 0 then
          MonitorSupport.WaitOrSignalObject(GetEvent, nil, 0);
        Break;
      end;
    end;
  end;
end;

class procedure TMonitor.Exit(AObject: TObject);
begin
  CheckMonitorSupport;
  GetMonitor(AObject).Exit;
end;

function TMonitor.GetEvent: Pointer;
var
  SleepTime: Integer;
  Event: Pointer;
begin
  SleepTime := 1;
  Result := FLockEvent;
  if Result = nil then
    while True do
    begin
      Event := MonitorSupport.NewSyncObject;
      Result := InterlockedCompareExchangePointer(FLockEvent, Event, nil);
      if Result = nil then
        // We won!  Nobody else was trying to allocate the Event.
        Result := Event
      else if Event <> nil then
        // Oh Well. We tried. Close the handle if someone got to it first.
        MonitorSupport.FreeSyncObject(Event);
      // Check if we actually were able to allocate the event without fail
      if Result <> nil then
        System.Exit;
      // We failed to allocate the event, so wait a bit to see if one becomes available
      Sleep(SleepTime);
      // Don't let it run-away, so return to a reasonable value and keep trying
      if SleepTime > 512 then
        SleepTime := 1
      else
        // Next time wait a little longer
        SleepTime := SleepTime shl 1;
    end;
end;

class function TMonitor.GetFieldAddress(AObject: TObject): PPMonitor;
begin
  Result := PPMonitor(PByte(AObject) + AObject.InstanceSize - hfFieldSize + hfMonitorOffset);
end;

class function TMonitor.GetMonitor(AObject: TObject): PMonitor;
var
  MonitorFld: PPMonitor;
  Monitor: PMonitor;
begin
  MonitorFld := GetFieldAddress(AObject);
  Result := MonitorFld^;
  if Result = nil then
  begin
    Monitor := TMonitor.Create;
    Result := InterlockedCompareExchangePointer(Pointer(MonitorFld^), Monitor, nil);
    if Result = nil then
      Result := Monitor
    else
      FreeMem(Monitor);
  end;
end;

procedure TMonitor.Pulse;
var
  WaitingThread: PWaitingThread;
begin
  WaitingThread := DequeueWaiter;
  if WaitingThread <> nil then
    MonitorSupport.WaitOrSignalObject(WaitingThread.WaitEvent, nil, 0);
end;

class procedure TMonitor.Pulse(AObject: TObject);
begin
  CheckMonitorSupport;
  GetMonitor(AObject).Pulse;
end;

procedure TMonitor.PulseAll;
var
  WaitingThread: PWaitingThread;
begin
  WaitingThread := DequeueWaiter;
  while WaitingThread <> nil do
  begin
    MonitorSupport.WaitOrSignalObject(WaitingThread.WaitEvent, nil, 0);
    WaitingThread := DequeueWaiter;
  end;
end;

class procedure TMonitor.PulseAll(AObject: TObject);
begin
  CheckMonitorSupport;
  GetMonitor(AObject).PulseAll;
end;

procedure TMonitor.QueueWaiter(var WaitingThread: TWaitingThread);
begin
  FQueueLock.Enter;
  try
    if FWaitQueue = nil then
    begin
      FWaitQueue := @WaitingThread;
      WaitingThread.Next := @WaitingThread;
    end else
    begin
      WaitingThread.Next := FWaitQueue.Next;
      FWaitQueue.Next := @WaitingThread;
      FWaitQueue := @WaitingThread;
    end;
  finally
    FQueueLock.Exit;
  end;
end;

procedure TMonitor.RemoveWaiter(var WaitingThread: TWaitingThread);
var
  Last, Walker: PWaitingThread;
begin
  // Perform a check, lock, check
  if FWaitQueue <> nil then
  begin
    FQueueLock.Enter;
    try
      if FWaitQueue <> nil then
      begin
        Last := FWaitQueue;
        Walker := Last.Next;
        while Walker <> FWaitQueue do
        begin
          if Walker = @WaitingThread then
          begin
            Last.Next := Walker.Next;
            Break;
          end;
          Last := Walker;
          Walker := Walker.Next;
        end;
        if (Walker = FWaitQueue) and (Walker = @WaitingThread) then
          if Walker.Next = Walker then
            FWaitQueue := nil
          else
          begin
            FWaitQueue := Walker.Next;
            Last.Next := FWaitQueue;
          end;
      end;
    finally
      FQueueLock.Exit;
    end;
  end;
end;

class procedure TMonitor.SetSpinCount(AObject: TObject; ASpinCount: Integer);
var
  Monitor: PMonitor;
begin
  if CPUCount > 1 then
  begin
    Monitor := GetMonitor(AObject);
    InterlockedExchange(Monitor.FSpinCount, ASpinCount);
  end;
end;

class function TMonitor.TryEnter(AObject: TObject): Boolean;
begin
  CheckMonitorSupport;
  Result := GetMonitor(AObject).TryEnter;
end;

function TMonitor.TryEnter: Boolean;
begin
  if FOwningThread = GetCurrentThreadId then  // check for recursion
  begin
    // Only the owning thread can increment this value so no need to guard it
    Inc(FRecursionCount);
    Result := True;
  // check to see if we can gain ownership
  end else if (FLockCount = 0) and (InterlockedCompareExchange(FLockCount, 1, 0) = 0) then
  begin
    //  Yep, got it.  Now claim ownership
    FOwningThread := GetCurrentThreadId;
    FRecursionCount := 1;
    Result := True;
  end else
    Result := False;
end;

function TMonitor.Wait(ALock: PMonitor; Timeout: Cardinal): Boolean;
var
  RecursionCount: Integer;
  WaitingThread: TWaitingThread;
begin
  WaitingThread.Next := nil;
  WaitingThread.Thread := ALock.CheckOwningThread;
  // This event should probably be cached someplace.
  // Probably not on the instance since this is a per-thread-per-instance resource
  WaitingThread.WaitEvent := MonitorSupport.NewWaitObject;
  try
    // Save the current recursion count for later
    RecursionCount := ALock.FRecursionCount;
    // Add the current thread to the waiting queue
    QueueWaiter(WaitingThread);
    // Set it back to almost released so the next Exit call actually drops the lock
    ALock.FRecursionCount := 1;
    // Now complete the exit and signal any waiters
    ALock.Exit;
    // Get in line for someone to do a Pulse or PulseAll
    Result := MonitorSupport.WaitOrSignalObject(nil, WaitingThread.WaitEvent, Timeout) = WAIT_OBJECT_0;
    // Got to get the lock back and block waiting for it.
    ALock.Enter(INFINITE);
    // Remove any dangling waiters from the list
    RemoveWaiter(WaitingThread);
    // Lets restore the recursion to return to the proper nesting level
    ALock.FRecursionCount := RecursionCount;
  finally
    MonitorSupport.FreeWaitObject(WaitingThread.WaitEvent);
  end;
end;

class function TMonitor.Wait(AObject: TObject; Timeout: Cardinal): Boolean;
var
  Monitor: PMonitor;
begin
  CheckMonitorSupport;
  Monitor := GetMonitor(AObject);
  Result := Monitor.Wait(Monitor, Timeout);
end;

class function TMonitor.Wait(AObject, ALock: TObject; Timeout: Cardinal): Boolean;
begin
  CheckMonitorSupport;
  Result := GetMonitor(AObject).Wait(GetMonitor(ALock), Timeout);
end;

function MonitorEnter(AObject: TObject; Timeout: Cardinal = INFINITE): Boolean;
begin
  Result := TMonitor.Enter(AObject, Timeout);
end;

function MonitorTryEnter(AObject: TObject): Boolean;
begin
  Result := TMonitor.TryEnter(AObject);
end;

procedure MonitorExit(AObject: TObject);
begin
  TMonitor.Exit(AObject);
end;

function MonitorWait(AObject: TObject; Timeout: Cardinal): Boolean;
begin
  Result := TMonitor.Wait(AObject, AObject, Timeout);
end;

function MonitorWait(AObject: TObject; ALock: TObject; Timeout: Cardinal): Boolean;
begin
  Result := TMonitor.Wait(AObject, ALock, Timeout);
end;

procedure MonitorPulse(AObject: TObject);
begin
  TMonitor.Pulse(AObject);
end;

procedure MonitorPulseAll(AObject: TObject);
begin
  TMonitor.PulseAll(AObject);
end;

procedure MemoryBarrier;
{$IF defined(CPUX64)}
asm
      MFENCE
end;
{$ELSEIF defined(CPUX86)}
asm
      PUSH EAX
      XCHG [ESP],EAX
      POP  EAX
end;
{$ELSE}
begin
  Error(rePlatformNotImplemented);
end;
{$IFEND}

procedure YieldProcessor;
{$IF defined(CPUX86) or defined(CPUX64)}
asm
  PAUSE
end;
{$ELSE}
begin
  Error(rePlatformNotImplemented);
end;
{$IFEND}

end.
