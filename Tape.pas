unit Tape;

{$mode unleashed}

interface

uses
  Classes, SysUtils, System.IOUtils,
  Z80;

const
  { Entry point of the 48K ROM's LD-BYTES routine. }
  LDBytesAddress = $0556;

type
  TMemReadProc = function(Address: UInt16): Byte;
  TMemWriteProc = procedure(Address: UInt16; Value: Byte);

var
  Blocks: array of TBytes;
  CurrentBlock: Integer = 0;
  TotalBlocks: Integer = 0;

{ Parses a .TAP file into Blocks, verbatim (flag byte + data + checksum byte
  per block, exactly as LD-BYTES expects to stream them). Resets the block
  cursor. Returns False (leaving Blocks empty) if the file can't be read or
  contains no blocks. }
function LoadTAP(const Filename: String): Boolean;

{ Implements the standard fast-load trap for LD-BYTES ($0556): consumes the
  next tape block per the routine's entry/exit register contract, then
  simulates the RET back to SA_LD_RET that the real routine would perform.
  MemRead/MemWrite must bypass memory contention bookkeeping - this is an
  instantaneous trap, not real bus activity. }
procedure HandleLoadTrap(CPU: PZ80; MemRead: TMemReadProc; MemWrite: TMemWriteProc);

implementation

function LoadTAP(const Filename: String): Boolean;
var
  FS: TFileStream;
  LenLo, LenHi: Byte;
  Len: Word;
  Block: TBytes;
begin
  SetLength(Blocks, 0);
  CurrentBlock := 0;
  TotalBlocks := 0;
  Result := False;

  if not FileExists(Filename) then Exit;

  FS := autofree TFile.OpenRead(Filename);
  while FS.Position < FS.Size do
  begin
    if (FS.Read(LenLo, 1) <> 1) or (FS.Read(LenHi, 1) <> 1 ) then Break;
    Len := LenLo or (Word(LenHi) shl 8);
    if Len = 0 then Continue;

    SetLength(Block, Len);
    if FS.Read(Block[0], Len) <> Len then Break;

    SetLength(Blocks, Length(Blocks) + 1);
    Blocks[High(Blocks)] := Block;
  end;

  TotalBlocks := Length(Blocks);
  Result := TotalBlocks > 0;
end;

procedure HandleLoadTrap(CPU: PZ80; MemRead: TMemReadProc; MemWrite: TMemWriteProc);
var
  Block: TBytes;
  ExpectedFlag, Checksum: Byte;
  RequestedLen, ActualLen: Word;
  IsLoad, Ok: Boolean;
  I: Integer;
  RetLo, RetHi: Byte;
begin
  ExpectedFlag := CPU^.af.bytes.high;
  IsLoad := (CPU^.af.bytes.low and Z80_CF) <> 0;
  RequestedLen := CPU^.de.word;
  Ok := False;

  if CurrentBlock < TotalBlocks then
  begin
    Block := Blocks[CurrentBlock];
    Inc(CurrentBlock);
  end
  else
    SetLength(Block, 0);

  if (Length(Block) >= 2) and (Block[0] = ExpectedFlag) then
  begin
    Checksum := 0;
    for I := 0 to High(Block) do
      Checksum := Checksum xor Block[I];

    if Checksum = 0 then
    begin
      ActualLen := Length(Block) - 2; { minus flag byte and trailing checksum byte }
      if ActualLen > RequestedLen then ActualLen := RequestedLen;

      if IsLoad then
      begin
        for I := 0 to ActualLen - 1 do
          MemWrite(CPU^.ix_iy[0].word + I, Block[1 + I]);
      end
      else
      begin
        Ok := True;
        for I := 0 to ActualLen - 1 do
          if MemRead(CPU^.ix_iy[0].word + I) <> Block[1 + I] then
          begin
            Ok := False;
            Break;
          end;
      end;

      CPU^.ix_iy[0].word := CPU^.ix_iy[0].word + ActualLen;
      CPU^.de.word := RequestedLen - ActualLen;

      Ok := (ActualLen = RequestedLen) and (IsLoad or Ok);
    end;
  end;

  if Ok then
    CPU^.af.bytes.low := CPU^.af.bytes.low or Z80_CF
  else
    CPU^.af.bytes.low := CPU^.af.bytes.low and not Z80_CF;

  { The caller (SAVE_ETC / LD_BLOCK) pushed SA_LD_RET before jumping here;
    simulate LD-BYTES's own RET back to it. }
  RetLo := MemRead(CPU^.sp.word);
  RetHi := MemRead(CPU^.sp.word + 1);
  CPU^.sp.word := CPU^.sp.word + 2;
  CPU^.pc.word := RetLo or (Word(RetHi) shl 8);
end;

end.
