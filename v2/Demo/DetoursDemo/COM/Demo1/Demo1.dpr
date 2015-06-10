program Demo1;

uses
  {$IFDEF DX2UP}
  Vcl.Forms,
  {$ENDIF}
  Forms,
  uMain in 'uMain.pas' {Main},
  CPUID in '..\..\..\..\src\CPUID.pas',
  DDetours in '..\..\..\..\src\DDetours.pas',
  InstDecode in '..\..\..\..\src\InstDecode.pas',
  TypePatch in '..\..\..\..\src\TypePatch.pas';

{$R *.res}

begin
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TMain, Main);
  Application.Run;
end.
