unit Spectrum;

{$mode unleashed}

interface

uses
  Classes, SysUtils, Math, System.IOUtils,
  Raylib,
  Z80, Tape;

type
  TZXColorIndex = 0..15;

  { Ink/paper colour pair already resolved from one attribute byte, indexed by
    pixel bit: [0] = paper, [1] = ink. }
  TPixelPair = array[0..1] of TColorB;
  TAttrTable = array[0..255] of TPixelPair;
  PAttrTable = ^TAttrTable;

  { The raylib image's raw R8G8B8A8 buffer, addressed directly. }
  TPixels = array[0..(352 * 288) - 1] of TColorB;
  PPixels = ^TPixels;

  TJoystickType = (jtNone, jtKempston, jtCursor);
  TJoystick = record
    Type_: TJoystickType;
    Keys: record
      Left, Right, Up, Down, Fire1, Fire2: TKeyboardKey;
    end;
  end;

  TAdvanceAudioNotify = procedure(ANewT: Integer) of object;

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
    Joystick: TJoystick;
    AdvanceAudio: TAdvanceAudioNotify;
    function OnMemoryRead(AAddress: Word): Byte;
    procedure OnMemoryWrite(AAddress: Word; AValue: Byte);
    function OnIORead(AAddress: Word): Byte;
    procedure OnIOWrite(AAddress: Word; AValue: Byte);
    function OnHook(AAddress: Word): Byte;
    property Contended: Boolean read FContended;
    property FlashPhase: Boolean read FFlashPhase;
    property CurrentScanline: Integer read FCurrentScanline;
    property BorderColorIndex: TZXColorIndex read FBorderColorIndex write SetBorderColorIndex;
    property Frames: QWord read FFrames;
    property Cycles: QWord read FCycles;
    property Power: Boolean read FPower write SetPower;
    property INT: Boolean read FINT write SetINT;
    constructor Create;
    procedure Reset;
    procedure Wait(ACycles: Integer);
    procedure Tick(ACycles: Integer);
    procedure BeginFrame;
    procedure RunScanline;
    procedure LoadZ80(AFilename: String);
    procedure LoadZ80(AStream: TStream);
    procedure SaveZ80(AFilename: String);
    procedure SaveZ80(AStream: TStream);
  end;

{$embedbytes ROMBytes '48.rom'}

implementation

function FetchCallback(Context: Pointer; Address: UInt16): UInt8; cdecl;
begin
  Result := TZXSpectrum48(Context).OnMemoryRead(Address);
end;

procedure WriteCallback(Context: Pointer; Address: UInt16; Value: UInt8); cdecl;
begin
  TZXSpectrum48(Context).OnMemoryWrite(Address, Value);
end;

function NMIACallback(Context: Pointer; address: UInt16): UInt8; cdecl;
begin
  Result := $FF;
end;

function INTACallback(Context: Pointer; address: UInt16): UInt8; cdecl;
begin
  { Writeln('INTA'); }
  { /INT is deasserted on a fixed 32 T-state schedule in the main loop,
    not here - see the pulse-width model there. }
  { On real Spectrum hardware nothing drives the data bus during the
    interrupt acknowledge cycle, so it floats and reads back as $FF.
    This only matters in IM2, where it's combined with the I register
    to look up the ISR address; IM1 ignores it (always RST 38h). }
  Result := $FF;
end;

function INTFetchCallback(Context: Pointer; address: UInt16): UInt8; cdecl;
begin
  Result := 0;
end;

function IllegalCallback(cpu: PZ80; opcode: UInt8): UInt8; cdecl;
begin
  Result := 0;
end;

procedure LDIACallback(Context: Pointer); cdecl;
begin

end;

procedure LDRACallback(Context: Pointer); cdecl;
begin

end;

procedure RETICallback(Context: Pointer); cdecl;
begin

end;

procedure RETNCallback(Context: Pointer); cdecl;
begin

end;

procedure HaltCallback(Context: Pointer; state: UInt8); cdecl;
begin

end;

function NopCallback(Context: Pointer; address: UInt16): UInt8; cdecl;
begin
  Result := 0;
end;

function HookCallback(Context: Pointer; Address: UInt16): UInt8; cdecl;
begin
  Result := TZXSpectrum48(Context).OnHook(Address);
end;

function InputCallback(Context: Pointer; Address: UInt16): UInt8; cdecl;
begin
  Result := TZXSpectrum48(Context).OnIORead(Address);
end;

procedure OutputCallback(Context: Pointer; Address: UInt16; Value: UInt8); cdecl;
begin
  TZXSpectrum48(Context).OnIOWrite(Address, Value);
end;

procedure TZXSpectrum48.SetPower(AValue: Boolean);
begin
  if FPower = AValue then Exit;
  FPower := AValue;
  z80_power(@CPU, AValue);
end;

function TZXSpectrum48.OnMemoryRead(AAddress: Word): Byte; inline;
begin
  Result := if AAddress < $4000
    then ROM[AAddress]
    else RAM[AAddress];

  if Contended and InRange(AAddress, $4000, $7FFF) then Wait(2);
end;

procedure TZXSpectrum48.OnMemoryWrite(AAddress: Word; AValue: Byte); inline;
begin
  if AAddress >= $4000 then RAM[AAddress] := AValue;
  if Contended and InRange(AAddress, $4000, $7FFF) then Wait(2);
end;

function TZXSpectrum48.OnIORead(AAddress: Word): Byte;
  function PollKeyboard(AMask: Byte): Byte;
  var
    Data: Byte;
  begin
    Result := 0;
    Data := 0;

    if not AMask.Bits[0] then
    begin
      { $FEFE }
      Data.Bits[0] := IsKeyDown(KEY_LEFT_SHIFT)
        or IsKeyDown(KEY_RIGHT_SHIFT)
        or IsKeyDown(KEY_BACKSPACE);
      Data.Bits[1] := IsKeyDown(KEY_Z);
      Data.Bits[2] := IsKeyDown(KEY_X);
      Data.Bits[3] := IsKeyDown(KEY_C);
      Data.Bits[4] := IsKeyDown(KEY_V);
      Result := Result or Data;
    end;

    if not AMask.Bits[1] then
    begin
      { $FDFE }
      Data.Bits[0] := IsKeyDown(KEY_A);
      Data.Bits[1] := IsKeyDown(KEY_S);
      Data.Bits[2] := IsKeyDown(KEY_D);
      Data.Bits[3] := IsKeyDown(KEY_F);
      Data.Bits[4] := IsKeyDown(KEY_G);
      Result := Result or Data;
    end;

    if not AMask.Bits[2] then
    begin
      { $FBFE }
      Data.Bits[0] := IsKeyDown(KEY_Q);
      Data.Bits[1] := IsKeyDown(KEY_W);
      Data.Bits[2] := IsKeyDown(KEY_E);
      Data.Bits[3] := IsKeyDown(KEY_R);
      Data.Bits[4] := IsKeyDown(KEY_T);
      Result := Result or Data;
    end;

    if not AMask.Bits[3] then
    begin
      { $F7FE }
      Data.Bits[0] := IsKeyDown(KEY_ONE);
      Data.Bits[1] := IsKeyDown(KEY_TWO);
      Data.Bits[2] := IsKeyDown(KEY_THREE);
      Data.Bits[3] := IsKeyDown(KEY_FOUR);
      Data.Bits[4] := IsKeyDown(KEY_FIVE);

      if Joystick.Type_ = jtCursor then
        Data.Bits[4] := Data.Bits[4] or IsKeyDown(KEY_LEFT);

      Result := Result or Data;
    end;

    if not AMask.Bits[4] then
    begin
      { $EFFE }
      Data.Bits[0] := IsKeyDown(KEY_ZERO) or IsKeyDown(KEY_BACKSPACE);
      Data.Bits[1] := IsKeyDown(KEY_NINE);
      Data.Bits[2] := IsKeyDown(KEY_EIGHT);
      Data.Bits[3] := IsKeyDown(KEY_SEVEN);
      Data.Bits[4] := IsKeyDown(KEY_SIX);

      if Joystick.Type_ = jtCursor then
      begin
        Data.Bits[0] := Data.Bits[0] or IsKeyDown(Joystick.Keys.Fire1);
        Data.Bits[2] := Data.Bits[2] or IsKeyDown(Joystick.Keys.Right);
        Data.Bits[3] := Data.Bits[3] or IsKeyDown(Joystick.Keys.Up);
        Data.Bits[4] := Data.Bits[4] or IsKeyDown(Joystick.Keys.Down);
      end;

      Result := Result or Data;
    end;

    if not AMask.Bits[5] then
    begin
      { $DFFE }
      Data.Bits[0] := IsKeyDown(KEY_P);
      Data.Bits[1] := IsKeyDown(KEY_O);
      Data.Bits[2] := IsKeyDown(KEY_I);
      Data.Bits[3] := IsKeyDown(KEY_U);
      Data.Bits[4] := IsKeyDown(KEY_Y);
      Result := Result or Data;
    end;

    if not AMask.Bits[6] then
    begin
      { $BFFE }
      Data.Bits[0] := IsKeyDown(KEY_ENTER);
      Data.Bits[1] := IsKeyDown(KEY_L)
        or IsKeyDown(KEY_EQUAL);
      Data.Bits[2] := IsKeyDown(KEY_K)
        or (IsKeyDown(KEY_KP_ADD));
      Data.Bits[3] := IsKeyDown(KEY_J)
        or IsKeyDown(KEY_MINUS);
      Data.Bits[4] := IsKeyDown(KEY_H);
      Result := Result or Data;
    end;

    if not AMask.Bits[7] then
    begin
      { $7FFE }
      Data.Bits[0] := IsKeyDown(KEY_SPACE);
      Data.Bits[1] := IsKeyDown(KEY_LEFT_CONTROL)
        or IsKeyDown(KEY_RIGHT_CONTROL)
        or IsKeyDown(KEY_KP_ADD)
        or IsKeyDown(KEY_MINUS)
        or IsKeyDown(KEY_EQUAL);
      Data.Bits[2] := IsKeyDown(KEY_M);
      Data.Bits[3] := IsKeyDown(KEY_N);
      Data.Bits[4] := IsKeyDown(KEY_B);
      Result := Result or Data;
    end;

    Result := not Result;
  end;

  function PollKempston: Byte;
  begin
    if Joystick.Type_ <> jtKempston then
    begin
      Result := $FF;
      Exit;
    end;

    Result := 0;
    Result.Bits[0] := IsKeyDown(Joystick.Keys.Right);
    Result.Bits[1] := IsKeyDown(Joystick.Keys.Left);
    Result.Bits[2] := IsKeyDown(Joystick.Keys.Down);
    Result.Bits[3] := IsKeyDown(Joystick.Keys.Up);
    Result.Bits[4] := IsKeyDown(Joystick.Keys.Fire1);
    Result.Bits[5] := IsKeyDown(Joystick.Keys.Fire2);
  end;

begin
  Result := $FF;

  if not AAddress.Bits[0] then
  begin
    if Contended then Wait(2);
    Result := Result and PollKeyboard(Hi(AAddress));
  end;

  if not AAddress.Bits[5] then
    Result := Result and PollKempston;
end;

procedure TZXSpectrum48.OnIOWrite(AAddress: Word; AValue: Byte); inline;
begin
  case AAddress.Bytes[0] of
    $FE:
      begin
        BorderColorIndex := AValue and %111;
        if Assigned(AdvanceAudio) then AdvanceAudio(Cycles + CPU.cycles);
        AudioPin := AValue.Bits[4];
      end;
  end;
end;

function TZXSpectrum48.OnHook(AAddress: Word): Byte;
begin
  if AAddress = LDBytesAddress then
  begin
    HandleLoadTrap(@CPU, @OnMemoryRead, @OnMemoryWrite);
    { The Z80 core treats the hook's return value as a fresh opcode to
      dispatch immediately UNLESS it's Z80_HOOK (see hook's INSN in
      Z80.c) - returning Z80_HOOK is what tells it "the hook fully
      replaced this instruction", leaving `pc` exactly where
      HandleLoadTrap's RET simulation set it, instead of also executing
      one stray extra instruction there first. }
    Result := Z80_HOOK;
  end
  else
    { Not our trap address - this is a real (if useless) LD H,H
      instruction elsewhere; let it behave as a harmless NOP rather than
      swallowing it as Z80_HOOK, which would leave `pc` stuck unadvanced. }
    Result := Z80_NOP;
end;

procedure TZXSpectrum48.SetINT(AValue: Boolean);
begin
  if FINT = AValue then Exit;
  FINT := AValue;
  z80_int(@CPU, AValue);
end;

procedure TZXSpectrum48.SetBorderColorIndex(AValue: TZXColorIndex); inline;
begin
  if FBorderColorIndex = AValue then Exit;
  FBorderColorIndex := AValue and %111;
end;

constructor TZXSpectrum48.Create;
begin
  with CPU do
  begin
    fetch := @FetchCallback;
    fetch_opcode := @FetchCallback;
    halt := @HaltCallback;
    read := @FetchCallback;
    write := @WriteCallback;
    hook := @HookCallback;
    input := @InputCallback;
    output := @OutputCallback;
    nop := @NopCallback;
    nmia := @NMIACallback;
    inta := @INTACallback;
    int_fetch := @INTFetchCallback;
    ld_i_a := @LDIACallback;
    ld_r_a := @LDRACallback;
    reti := @RETICallback;
    retn := @RETNCallback;
    illegal := @IllegalCallback;
    context := Self;
  end;

  with Joystick do
  begin
    Type_ := jtKempston;
    with Joystick.Keys do
    begin
      Left := KEY_LEFT;
      Right := KEY_RIGHT;
      Up := KEY_UP;
      Down := KEY_DOWN;
      Fire1 := KEY_LEFT_ALT;
      Fire2 := KEY_RIGHT_ALT;
    end;
  end;

  Reset;
end;

procedure TZXSpectrum48.Reset;
begin
  FFrames := 0;
  FCycles := 0;
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
const
  INTLine = 295; { Has to be 64 line times before the first byte
                   of the screen (16384) is displayed. }
begin
  case FCurrentScanline of
    47..239:
      begin
        FContended := True;
        Tick(128);
        FContended := False;
        Tick(96);
      end;

    INTLine:
      begin
        INT := True;
        Tick(32);
        INT := False;
        Tick(192);
    end;

  else
    Tick(224);
  end;

  Inc(FCurrentScanline);
end;

procedure TZXSpectrum48.LoadZ80(AFilename: String);
var
  Stream: TFileStream;
begin
  Stream := autofree TFile.OpenRead(AFilename);
  LoadZ80(Stream);
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
  Reset;

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

procedure TZXSpectrum48.SaveZ80(AFilename: String);
var
  Stream: TFileStream;
begin
  Stream := autofree TFile.OpenOrCreate(AFilename);
  SaveZ80(Stream);
end;

procedure TZXSpectrum48.SaveZ80(AStream: TStream);
var
  Data: Byte = 0;
begin
  with AStream do
  begin
    WriteByte(CPU.af.bytes.high);
    WriteByte(CPU.af.bytes.low);
    WriteWord(CPU.bc.word);
    WriteWord(CPU.hl.word);
    WriteWord(CPU.pc.word);
    WriteWord(CPU.sp.word);
    WriteByte(CPU.i);
    WriteByte(CPU.r);

    Data.Bits[0] := CPU.r.Bits[7];
    Data := Data or (BorderColorIndex shl 1);
    Data.Bits[5] := False;  { Uncompressed }
    WriteByte(Data);

    WriteWord(CPU.de.word);
    WriteWord(CPU.bc_.word);
    WriteWord(CPU.de_.word);
    WriteWord(CPU.hl_.word);
    WriteByte(CPU.af_.bytes.high);
    WriteByte(CPU.af_.bytes.low);
    WriteWord(CPU.ix_iy[1].word);
    WriteWord(CPU.ix_iy[0].word);

    WriteByte(CPU.iff1);
    WriteByte(CPU.iff2);
    WriteByte(CPU.im);

    WriteBuffer(RAM, SizeOf(RAM));
  end;
end;

end.
