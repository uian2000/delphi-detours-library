unit TypePatch;

interface

{$I Defs.inc}

{$IF CompilerVersion <= 18.5}
type
  Int8 = ShortInt;
  UInt8 = Byte;
  Int16 = SmallInt;
  UInt16 = Word;
  Int32 = LongInt;
  UInt32 = LongWord;
{$IFEND}

implementation

end.
