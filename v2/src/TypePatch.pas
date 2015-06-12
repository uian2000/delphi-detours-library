unit TypePatch;

interface

{$I Defs.inc}

{$IFNDEF NewTypeExist}
type
  Int8 = ShortInt;
  UInt8 = Byte;
  Int16 = SmallInt;
  UInt16 = Word;
  Int32 = LongInt;
  UInt32 = LongWord;
  PNativeUInt = ^NativeUInt;
{$ENDIF}

implementation

end.
