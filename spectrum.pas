unit Spectrum;

{$mode unleashed}

interface

uses
  Classes, SysUtils, Math,
  Z80;

type
  TZXColorIndex = 0..15;

  TZXSpectrum48 = class
  private
    FBorderColorIndex: TZXColorIndex;
    FContended: Boolean;
    FCurrentScanline: Integer;
    FCycles: QWord;
    FFlashPhase: Boolean;
    FOvershoot: Integer;
    FFrames: QWord;
    FINT: Boolean;
    FPower: Boolean;
    procedure SetBorderColorIndex(AValue: TZXColorIndex);
    procedure SetINT(AValue: Boolean);
    procedure SetPower(AValue: Boolean);
  public
    CPU: TZ80;
    ROM: array[0..$3FFF] of Byte;
    RAM: array[$4000..$FFFF] of Byte;
    AudioPin: Boolean;
    property Contended: Boolean read FContended;
    property FlashPhase: Boolean read FFlashPhase;
    property CurrentScanline: Integer read FCurrentScanline;
    property BorderColorIndex: TZXColorIndex read FBorderColorIndex write SetBorderColorIndex;
    property Frames: QWord read FFrames;
    property Cycles: QWord read FCycles;
    property Power: Boolean read FPower write SetPower;
    property INT: Boolean read FINT write SetINT;
    constructor Create;
    procedure Wait(ACycles: Integer);
    procedure Tick(ACycles: Integer);
    procedure BeginFrame;
    procedure RunScanline;
    procedure LoadZ80(AStream: TStream);
  end;

{$embedbytes ROMBytes '48.rom'}

implementation

procedure TZXSpectrum48.SetPower(AValue: Boolean);
begin
  if FPower = AValue then Exit;
  FPower := AValue;
  z80_power(@CPU, AValue);
end;

procedure TZXSpectrum48.SetINT(AValue: Boolean);
begin
  if FINT = AValue then Exit;
  FINT := AValue;
  z80_int(@CPU, AValue);
end;

procedure TZXSpectrum48.SetBorderColorIndex(AValue: TZXColorIndex);
begin
  if FBorderColorIndex = AValue then Exit;
  FBorderColorIndex := AValue and %111;
end;

constructor TZXSpectrum48.Create;
begin
  Move(ROMBytes, ROM, SizeOf(ROMBytes));
end;

procedure TZXSpectrum48.Wait(ACycles: Integer); inline;
begin
  Inc(CPU.cycles, ACycles);
end;

procedure TZXSpectrum48.Tick(ACycles: Integer); inline;
var
  Requested, Fact: Integer;
begin
  Requested := Max(ACycles - FOvershoot, 0);
  Fact := z80_run(@CPU, Requested);
  FOvershoot := Fact - Requested;
  Inc(FCycles, Fact);
end;

procedure TZXSpectrum48.RunScanline; inline;
begin
  if FCurrentScanline <> 7 then
    Tick(224)
  else
  begin
    Tick(192);
    INT := True;
    Tick(32);
    INT := False;
  end;

  Inc(FCurrentScanline);
  FContended := InRange(FCurrentScanline, 48, 255);
end;

procedure TZXSpectrum48.BeginFrame;
begin
  FCycles := 0;
  Inc(FFrames);
  FCurrentScanline := 0;
  FFlashPhase := Odd(Frames div 16);
end;

procedure TZXSpectrum48.LoadZ80(AStream: TStream);
var
  Data, ExtData: Byte;
  Addr: Integer;
  Compressed: Boolean;
  PC1: UInt16;
  HeaderLen: UInt16;
  HWMode: Byte;
  BlockLen: UInt16;
  PageNum: Byte;
  BlockEnd: Int64;

  { Decompresses a run of ED-ED-count-value encoded bytes from Stream into
    Memory, starting at StartAddr, until Stream.Position reaches EndPos.
    StartAddr < 0 means "discard" (used to skip unsupported 128K pages). }
  procedure DecodeBlock(StartAddr: Integer; EndPos: Int64);
  var
    CurAddr, I: Integer;
  begin
    CurAddr := StartAddr;
    while AStream.Position < EndPos do
    begin
      Data := AStream.ReadByte;
      if Data = $ED then
      begin
        ExtData := AStream.ReadByte;
        if ExtData = $ED then
        begin
          Data := AStream.ReadByte;
          ExtData := AStream.ReadByte;
          for I := 1 to Data do
          begin
            if CurAddr >= 0 then RAM[CurAddr] := ExtData;
            Inc(CurAddr);
          end;
        end else
        begin
          if CurAddr >= 0 then
          begin
            RAM[CurAddr] := Data;
            RAM[CurAddr + 1] := ExtData;
          end;
          Inc(CurAddr, 2);
        end;
      end else
      begin
        if CurAddr >= 0 then RAM[CurAddr] := Data;
        Inc(CurAddr);
      end;
    end;
  end;

begin
  CPU.af.bytes.high := AStream.ReadByte;
  CPU.af.bytes.low := AStream.ReadByte;
  CPU.bc.word := AStream.ReadWord;
  CPU.hl.word := AStream.ReadWord;
  PC1 := AStream.ReadWord; { 0 here means this is actually a v2/v3 snapshot }
  CPU.sp.word := AStream.ReadWord;
  CPU.i := AStream.ReadByte;
  CPU.r := AStream.ReadByte;

  Data := AStream.ReadByte;
  CPU.r.Bits[7] := Data.Bits[0];
  BorderColorIndex := (Data shr 1) and %111;
  Compressed := Data.Bits[5];

  CPU.de.word := AStream.ReadWord;
  CPU.bc_.word := AStream.ReadWord;
  CPU.de_.word := AStream.ReadWord;
  CPU.hl_.word := AStream.ReadWord;
  CPU.af_.bytes.high := AStream.ReadByte;
  CPU.af_.bytes.low := AStream.ReadByte;
  CPU.ix_iy[1].word := AStream.ReadWord;
  CPU.ix_iy[0].word := AStream.ReadWord;

  CPU.iff1 := AStream.ReadByte; { Interrupt flipflop, 0=DI, otherwise EI }
  CPU.iff2 := AStream.ReadByte; { IFF2 (not particularly important...) }
  CPU.im := AStream.ReadByte and %11;

  if PC1 <> 0 then
  begin
    { Version 1: PC sits in the base header, and one flat block holds the
      whole 48K RAM image. }
    CPU.pc.word := PC1;

    if Compressed then
      DecodeBlock(16384, AStream.Size - 4)
    else
      AStream.Read(RAM[16384], AStream.Size - AStream.Position);
  end else
  begin
    { Version 2/3: PC=0 in the base header is the marker that an extended
      header follows, holding the real PC, then memory arrives as separate
      page-numbered blocks rather than one flat image. The "Compressed" flag
      read above is a v1-only field and has no meaning here - each block
      carries its own length instead. }
    HeaderLen := AStream.ReadWord;
    CPU.pc.word := AStream.ReadWord;
    HWMode := AStream.ReadByte;
    AStream.Position := AStream.Position + (HeaderLen - 3);

    while AStream.Position < AStream.Size do
    begin
      BlockLen := AStream.ReadWord;
      PageNum := AStream.ReadByte;

      { 48K page numbering; other pages are 128K banks / ROM, unsupported
        by this emulator's flat memory model, so they're skipped. }
      case PageNum of
        4: Addr := $8000;
        5: Addr := $C000;
        8: Addr := $4000;
        else Addr := -1;
      end;

      if BlockLen = $FFFF then
      begin
        { Uncompressed 16K page }
        if Addr >= 0 then
          AStream.Read(RAM[Addr], 16384)
        else
          AStream.Position := AStream.Position + 16384;
      end else
      begin
        BlockEnd := AStream.Position + BlockLen;
        DecodeBlock(Addr, BlockEnd);
      end;
    end;
  end;
end;


end.
