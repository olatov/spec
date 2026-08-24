program Spec;

{$mode unleashed}

{$ifdef Darwin}
  {$linkframework Cocoa}
  {$linkframework IOKit}
{$endif}

uses
  Classes, Sysutils, CTypes, Math,
  Raylib, Raymath,
  Z80;

type
  TJoystickType = (jkNone, jkKempston, jkCursor);
  TJoystick = record
    Type_: TJoystickType;
    Keys: record
      Left, Right, Up, Down, Fire1, Fire2: TKeyboardKey;
    end;
  end;

const
  ScanlineTStates = 224;
  TotalScanlines = 312;
  TStatesPerFrame = ScanlineTStates * TotalScanlines;
  SamplesPerFrame = 441; { 22050Hz / 50fps }
  AudioChunkFrames = SamplesPerFrame * 5; { must stay >= the audio device's internal period size, or
    raylib pads the shortfall with raw zero bytes - which is true silence for signed
    16-bit PCM, so a shortfall now degrades to silence instead of a loud click }
  AudioHigh: CInt16 = CInt16.MaxValue;
  AudioLow: CInt16 = CInt16.MinValue;

var
  CPU: TZ80;
  Memory: array[4000..$ffff] of Byte;
  BorderColorIndex: Byte;
  Snapshot: String = '';
  Cycles: Integer = 0;
  Overshoot: Integer = 0;
  ABuf: array[0..SamplesPerFrame - 1] of CInt16;
  AudioStream: TAudioStream;
  AudioPin: Boolean = False;
  OSD: record
    Text: String;
    Lifetime: Double;
  end;
  PrevTiming: Integer = 0;   { index of the sample bucket currently being accumulated }
  PrevT: Integer = 0;        { T-state at which that accumulation last left off }
  BucketStartT: Integer = 0; { T-state at which the current bucket began }
  BucketHigh: Integer = 0;   { T-states spent HIGH within the current bucket so far }
  AccumBuf: array[0..AudioChunkFrames - 1] of CInt16;
  AccumPos: Integer = 0;
  Contended: Boolean = False;
  Joystick: TJoystick;
  {$embedstr ShaderText 'shader.fs'}
  {$embedbytes ROMBytes '48.rom'}

{ Advances the audio-sample cursor to absolute T-state NewT, treating AudioPin as having
  held constant since the last call. Rather than snapshotting one instant per output sample
  (which aliases high-pitched beeper toggling - e.g. Wham!'s PWM-style tricks - into audible
  spurious tones), each finished bucket is written as the pin's HIGH duty cycle over its
  exact T-state span: a boxcar low-pass filter matched to the sample rate. }
function BucketBoundary(Index: Integer): Integer; inline;
begin
  Result := (Index * TStatesPerFrame) div SamplesPerFrame;
end;

procedure AdvanceAudio(NewT: Integer);
var
  NextBoundary, Duration: Integer;
begin
  while PrevTiming < SamplesPerFrame do
  begin
    NextBoundary := BucketBoundary(PrevTiming + 1);
    if NextBoundary > NewT then Break;

    if AudioPin then Inc(BucketHigh, NextBoundary - PrevT);
    Duration := NextBoundary - BucketStartT;
    ABuf[PrevTiming] := CInt16(AudioLow + (BucketHigh * (Integer(AudioHigh) - AudioLow)) div Duration);

    PrevT := NextBoundary;
    BucketStartT := NextBoundary;
    BucketHigh := 0;
    Inc(PrevTiming);
  end;

  if AudioPin then Inc(BucketHigh, NewT - PrevT);
  PrevT := NewT;
end;

procedure OnHalt(context: Pointer; state: UInt8); cdecl;
begin
  { Writeln('HALT'); }
end;

function OnNop(context: Pointer; address: UInt16): UInt8; cdecl;
begin
  { WriteLn('NOP'); }
  Result := 0;
end;

function OnHook(context: Pointer; address: UInt16): UInt8; cdecl;
begin
  WriteLn('HOOK');
  Result := 0;
end;

function OnMemoryRead(context: Pointer; address: UInt16): UInt8; cdecl;
begin
  { WriteLn('MEMORY READ addr ', address); }
  Result := if address < $4000 then ROMBytes[address] else Memory[address];
  if Contended and InRange(Address, $4000, $7FFF) then
    CPU.cycles := CPU.cycles + 1;
end;

procedure OnMemoryWrite(context: Pointer; address: UInt16; value: UInt8); cdecl;
begin
  { WriteLn('MEMORY WRITE addr ', address, ', val ', value); }
  if address < $4000 then Exit; { ROM }
  Memory[address] := value;
  if Contended and InRange(Address, $4000, $7FFF) then
    CPU.cycles := CPU.cycles + 1;
end;

function OnIORead(context: Pointer; address: UInt16): UInt8; cdecl;
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

      if Joystick.Type_ = jkCursor then
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

      if Joystick.Type_ = jkCursor then
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
    Result := 0;
    Result.Bits[0] := IsKeyDown(Joystick.Keys.Right);
    Result.Bits[1] := IsKeyDown(Joystick.Keys.Left);
    Result.Bits[2] := IsKeyDown(Joystick.Keys.Down);
    Result.Bits[3] := IsKeyDown(Joystick.Keys.Up);
    Result.Bits[4] := IsKeyDown(Joystick.Keys.Fire1);
    Result.Bits[5] := IsKeyDown(Joystick.Keys.Fire2);
  end;

begin
  { WriteLn('IO READ addr ', IntToHex(address, 4)); }

  if not Odd(address) then
  begin
    Result := PollKeyboard(Hi(address));
    Exit;
  end;

  case Joystick.Type_ of
    jkKempston: Result := PollKempston
  else
    Result := $FF;
  end;
end;

procedure OnIOWrite(context: Pointer; address: UInt16; value: UInt8); cdecl;
begin
  case address.Bytes[0] of
    $FE:
      begin
        BorderColorIndex := value and %111;
        AdvanceAudio(Cycles + CPU.cycles);
        AudioPin := value.Bits[4];
      end;
  end;
end;

function OnNMIA(context: Pointer; address: UInt16): UInt8; cdecl;
begin
  { Writeln('NMIA'); }
end;

function OnINTA(context: Pointer; address: UInt16): UInt8; cdecl;
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

function OnINTFetch(context: Pointer; address: UInt16): UInt8; cdecl;
begin
  { Writeln('INT fetch'); }
end;

function OnIllegal(cpu: PZ80; opcode: UInt8): UInt8; cdecl;
begin
  { WriteLn('Illegal'); }
end;

procedure OnLDIA(context: Pointer); cdecl;
begin
  { WriteLn('LDIA'); }
end;

procedure OnLDRA(context: Pointer); cdecl;
begin
  { WriteLn('LDRA'); }
end;

procedure OnRETI(context: Pointer); cdecl;
begin
  { WriteLn('RETI'); }
end;

procedure OnRETN(context: Pointer); cdecl;
begin
  { WriteLn('RETN'); }
end;

procedure LoadSNA(Z80: PZ80; Filename: String);
begin

end;

procedure Run(ACycles: Integer); inline;
var
  Requested, Fact: Integer;
begin
  Requested := Max(ACycles - Overshoot, 0);
  Fact := z80_run(@CPU, Requested);
  //Writeln($'CPU requested: {ACycles}, fact: {Fact}');
  Overshoot := Fact - Requested;
  Inc(Cycles, Fact);
end;

procedure LoadZ80(Z80: PZ80; Filename: String);
var
  Stream: TBytesStream;
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
    while Stream.Position < EndPos do
    begin
      Data := Stream.ReadByte;
      if Data = $ED then
      begin
        ExtData := Stream.ReadByte;
        if ExtData = $ED then
        begin
          Data := Stream.ReadByte;
          ExtData := Stream.ReadByte;
          for I := 1 to Data do
          begin
            if CurAddr >= 0 then Memory[CurAddr] := ExtData;
            Inc(CurAddr);
          end;
        end else
        begin
          if CurAddr >= 0 then
          begin
            Memory[CurAddr] := Data;
            Memory[CurAddr + 1] := ExtData;
          end;
          Inc(CurAddr, 2);
        end;
      end else
      begin
        if CurAddr >= 0 then Memory[CurAddr] := Data;
        Inc(CurAddr);
      end;
    end;
  end;

begin
  Stream := autofree TBytesStream.Create;
  Stream.LoadFromFile(Filename);

  Z80^.af.bytes.high := Stream.ReadByte;
  Z80^.af.bytes.low := Stream.ReadByte;
  Z80^.bc.word := Stream.ReadWord;
  Z80^.hl.word := Stream.ReadWord;
  PC1 := Stream.ReadWord; { 0 here means this is actually a v2/v3 snapshot }
  Z80^.sp.word := Stream.ReadWord;
  Z80^.i := Stream.ReadByte;
  Z80^.r := Stream.ReadByte;

  Data := Stream.ReadByte;
  Z80^.r.Bits[7] := Data.Bits[0];
  BorderColorIndex := (Data shr 1) and %111;
  Compressed := Data.Bits[5];

  Z80^.de.word := Stream.ReadWord;
  Z80^.bc_.word := Stream.ReadWord;
  Z80^.de_.word := Stream.ReadWord;
  Z80^.hl_.word := Stream.ReadWord;
  Z80^.af_.bytes.high := Stream.ReadByte;
  Z80^.af_.bytes.low := Stream.ReadByte;
  Z80^.ix_iy[1].word := Stream.ReadWord;
  Z80^.ix_iy[0].word := Stream.ReadWord;

  Z80^.iff1 := Stream.ReadByte; { Interrupt flipflop, 0=DI, otherwise EI }
  Z80^.iff2 := Stream.ReadByte; { IFF2 (not particularly important...) }
  Z80^.im := Stream.ReadByte and %11;

  if PC1 <> 0 then
  begin
    { Version 1: PC sits in the base header, and one flat block holds the
      whole 48K RAM image. }
    Z80^.pc.word := PC1;

    if Compressed then
      DecodeBlock(16384, Stream.Size - 4)
    else
      Stream.Read(Memory[16384], Stream.Size - Stream.Position);
  end else
  begin
    { Version 2/3: PC=0 in the base header is the marker that an extended
      header follows, holding the real PC, then memory arrives as separate
      page-numbered blocks rather than one flat image. The "Compressed" flag
      read above is a v1-only field and has no meaning here - each block
      carries its own length instead. }
    HeaderLen := Stream.ReadWord;
    Z80^.pc.word := Stream.ReadWord;
    HWMode := Stream.ReadByte;
    Stream.Position := Stream.Position + (HeaderLen - 3);

    while Stream.Position < Stream.Size do
    begin
      BlockLen := Stream.ReadWord;
      PageNum := Stream.ReadByte;

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
          Stream.Read(Memory[Addr], 16384)
        else
          Stream.Position := Stream.Position + 16384;
      end else
      begin
        BlockEnd := Stream.Position + BlockLen;
        DecodeBlock(Addr, BlockEnd);
      end;
    end;
  end;
end;

procedure SetOSD(AText: String; ADuration: Double = 2);
begin
  OSD.Text := AText;
  OSD.Lifetime := GetTime + ADuration;
end;

procedure Main;
var
  Target: TRenderTexture2D;
  Image: TImage;
  Video: TTexture2D;
  Colors: PColorB;
  Row, I, Addr, Col, Offset, J, LinesLoc: Integer;
  Data, Attribute: Byte;
  Palette: array[0..15] of TColorB;
  InkColorIndex, PaperColorIndex: Byte;
  Flash, FlashPhase: Boolean;
  Frames: QWord = 0;
  Paused: Boolean = False;
  Fullscreen: Boolean = False;
  LinesCount: Single = 288;
  Shader: TShader;
  ScanlinesEnabled: Int32 = 1;
  GrayscaleEnabled: Int32 = 0;
  CurvatureEnabled: Int32 = 1;
  MaskEnabled: Int32 = 1;
  Curvature: Single = 7.5;
  OldTV: Boolean = True;
  S: String;

  procedure DrawBorderLine(ALine: Integer); inline;
  begin
    if ALine >= Image.height then Exit;
    ImageDrawLine(@Image, 0, ALine, 351, ALine, Palette[BorderColorIndex]);
  end;

begin
  if not LoadLibrary then
  begin
    WriteLn('Fatal: failed to load Z80 library.');
    Halt(1);
  end;

  Palette := [
    GetColor($000000FF),
    GetColor($0000D8FF),
    GetColor($D80000FF),
    GetColor($D800D8FF),
    GetColor($00D800FF),
    GetColor($00D8D8FF),
    GetColor($D8D800FF),
    GetColor($D8D8D8FF),

    GetColor($000000FF),
    GetColor($0000FFFF),
    GetColor($FF0000FF),
    GetColor($FF00FFFF),
    GetColor($00FF00FF),
    GetColor($00FFFFFF),
    GetColor($FFFF00FF),
    GetColor($FFFFFFFF)
  ];

  FillByte(CPU, SizeOf(CPU), 0);

  z80_power(@CPU, True);

  if ParamCount > 0 then Snapshot := ParamStr(1);

  if not Snapshot.IsEmpty then
  begin
    if not Snapshot.EndsWith('.z80') then Snapshot := Snapshot + '.z80';
    LoadZ80(@CPU, Snapshot);
  end;

  with CPU do
  begin
    fetch := @OnMemoryRead;
    fetch_opcode := @OnMemoryRead;
    halt := @OnHalt;
    read := @OnMemoryRead;
    write := @OnMemoryWrite;
    hook := @OnHook;
    input := @OnIORead;
    output := @OnIOWrite;
    nop := @OnNop;
    nmia := @OnNMIA;
    inta := @OnINTA;
    int_fetch := @OnINTFetch;
    ld_i_a := @OnLDIA;
    ld_r_a := @OnLDRA;
    reti := @OnRETI;
    retn := @OnRETN;
    illegal := @OnIllegal;
  end;

  with Joystick do
  begin
    Type_ := jkKempston;
    with Joystick.Keys do
    begin
      Left := KEY_LEFT;
      Right := KEY_RIGHT;
      Up := KEY_UP;
      Down := KEY_DOWN;
      Fire1 := KEY_LEFT_ALT;
      Fire2 := KEY_SPACE;
    end;
  end;

  SetTraceLogLevel(LOG_ERROR);

  //SetConfigFlags(FLAG_WINDOW_HIGHDPI);
  InitWindow(720, 576, 'Spec');
  SetTargetFPS(50);

  Fullscreen := True;
  ToggleBorderlessWindowed;
  HideCursor;

  Target := LoadRenderTexture(352, 288);
  SetTextureFilter(Target.texture, TEXTURE_FILTER_BILINEAR);
  SetTextureWrap(Target.texture, TEXTURE_WRAP_CLAMP);

  Shader := LoadShaderFromMemory(Nil, @ShaderText[1]);

  LinesCount := 288 - 32;
  LinesLoc := GetShaderLocation(Shader, 'lines');
  SetShaderValue(Shader, LinesLoc, @LinesCount, SHADER_UNIFORM_FLOAT);

  SetShaderValue(Shader,
    GetShaderLocation(Shader, 'enableGrayscale'),
    @GrayscaleEnabled, SHADER_UNIFORM_INT);

  SetShaderValue(Shader,
    GetShaderLocation(Shader, 'enableScanlines'),
    @ScanlinesEnabled, SHADER_UNIFORM_INT);

  SetShaderValue(Shader,
    GetShaderLocation(Shader, 'enableCurvature'),
    @CurvatureEnabled, SHADER_UNIFORM_INT);

  SetShaderValue(Shader,
    GetShaderLocation(Shader, 'enableMask'),
    @MaskEnabled, SHADER_UNIFORM_INT);

  SetShaderValue(Shader,
    GetShaderLocation(Shader, 'curvature'),
    @Curvature, SHADER_UNIFORM_FLOAT);

  Image := GenImageColor(352, 288, BLACK);
  Video := LoadTextureFromImage(Image);

  InitAudioDevice;

  SetAudioStreamBufferSizeDefault(AudioChunkFrames);
  AudioStream := LoadAudioStream(22050, 16, 1);
  SetAudioStreamVolume(AudioStream, 0.25);
  PlayAudioStream(AudioStream);

  FillByte(AccumBuf, SizeOf(AccumBuf), 0); { 0 = silence for signed 16-bit PCM }

  for I := 1 to 3 do
    if IsAudioStreamProcessed(AudioStream) then
      UpdateAudioStream(AudioStream, @AccumBuf, AudioChunkFrames);

  while not WindowShouldClose do
  begin
    if IsKeyPressed(KEY_F9) then
    begin
      OldTV := not OldTV;
      ScanlinesEnabled := IfThen(OldTV, 1, 0);
      MaskEnabled := IfThen(OldTV, 1, 0);
      CurvatureEnabled := IfThen(OldTV, 1, 0);

      SetShaderValue(Shader,
        GetShaderLocation(Shader, 'enableScanlines'),
        @ScanlinesEnabled, SHADER_UNIFORM_INT);

      SetShaderValue(Shader,
        GetShaderLocation(Shader, 'enableCurvature'),
        @CurvatureEnabled, SHADER_UNIFORM_INT);

      SetShaderValue(Shader,
        GetShaderLocation(Shader, 'enableMask'),
        @MaskEnabled, SHADER_UNIFORM_INT);
    end;

    if IsKeyPressed(KEY_F7) then
    begin
      Joystick.Type_ := if Joystick.Type_ <> High(TJoystickType)
        then Succ(Joystick.Type_)
        else Low(TJoystickType);

      case Joystick.Type_ of
        jkNone: S := 'Off';
        jkKempston: S := 'Kempston';
        jkCursor: S := 'Cursor';
      end;

      SetOSD($'Joystick: {S}');
    end;

    if IsKeyPressed(KEY_F10) then Paused := not Paused;
    if IsKeyPressed(KEY_F11) then
    begin
      ToggleBorderlessWindowed;
      Fullscreen := not Fullscreen;
      if Fullscreen then
        HideCursor
      else
        ShowCursor;
    end;

    if not Paused then
    begin
      Inc(Frames);
      Cycles := 0;

      AdvanceAudio(TStatesPerFrame);
      PrevTiming := 0;
      PrevT := 0;
      BucketStartT := 0;
      BucketHigh := 0;

      Move(ABuf, AccumBuf[AccumPos], SamplesPerFrame * SizeOf(CInt16));
      Inc(AccumPos, SamplesPerFrame);
      if AccumPos >= AudioChunkFrames then
      begin
        if IsAudioStreamProcessed(AudioStream) then
          UpdateAudioStream(AudioStream, @AccumBuf, AudioChunkFrames);
        AccumPos := 0;
      end;

      Run((ScanlineTStates * 8) - 32);  { VBlank }
      z80_int(@CPU, True);
      Run(32);
      z80_int(@CPU, False);

      Run((ScanlineTStates * 8)); { "Unvisible" top border }

      Row := 0;

      { Top border }
      for I := 1 to 48 do
      begin
        DrawBorderLine(Row);
        Run(ScanlineTStates);
        Inc(Row);
      end;

      //ImageDrawRectangle(@Image, 0, 0, 352, 288, Palette[BorderColorIndex and $07]);

      FlashPhase := Odd(Frames div 16);

      Contended := True;
      for I := 0 to 191 do
      begin
        DrawBorderLine(Row);
        Offset := 16384;
        Inc(Offset, (I div 64) * 2048);
        Inc(Offset, ((I mod 64) div 8) * 32);
        Inc(Offset, (I mod 8) * 256);

        Col := 0;
        for Addr := Offset to Offset + 31 do
        begin
          Data := Memory[Addr];
          if (Col mod 8) = 0 then
          begin
            //Attribute := 7 shl 3;
            Attribute := Memory[22528 + ((I div 8) * 32) + (Col div 8)];
            Flash := Attribute.Bits[7];
            InkColorIndex := Attribute and %111;
            InkColorIndex.Bits[3] := Attribute.Bits[6];
            PaperColorIndex := (Attribute shr 3) and %111;
            PaperColorIndex.Bits[3] := Attribute.Bits[6];

            if Flash and FlashPhase then
              Swap<Byte>(InkColorIndex, PaperColorIndex);
          end;

          for J := 7 downto 0 do
          begin
            ImageDrawPixel(@Image,
              Col + 48, Row,
              Palette[if Data.Bits[J] then InkColorIndex else PaperColorIndex]);
            Inc(Col);
          end;
        end;
        Run(ScanlineTStates);
        Inc(Row);
      end;
      Contended := False;

      { Bottom border }
      for I := 1 to 56 do
      begin
        DrawBorderLine(Row);
        Run(ScanlineTStates);
        Inc(Row);
      end;

      Colors := LoadImageColors(Image);
      UpdateTexture(Video, Colors);
      UnloadImageColors(Colors);
    end;

    BeginTextureMode(Target);
    DrawTexture(Video, 0, 0, WHITE);
    if not OSD.Text.IsEmpty then
      if GetTime < OSD.Lifetime then
        DrawText(PAnsiChar(OSD.Text), 18, 18, 16, ORANGE)
      else
        OSD.Text := '';
    EndTextureMode;

    BeginDrawing;
    ClearBackground(BLACK);
    BeginShaderMode(Shader);
    DrawTexturePro(
      Target.Texture,
      RectangleCreate(16, 16, Target.texture.width - 32, -Target.texture.height + 32),
      RectangleCreate(0.5 * GetScreenWidth - (GetScreenHeight * 0.667), 0, GetScreenHeight * 1.333, GetScreenHeight),
      Vector2Zero, 0, WHITE);
    EndShaderMode;
    { DrawFPS(10, 10); }

    EndDrawing;
  end;

  StopAudioStream(AudioStream);
  UnloadAudioStream(AudioStream);
  CloseAudioDevice;

  UnloadShader(Shader);
  UnloadImage(Image);
  UnloadTexture(Video);
  UnloadRenderTexture(Target);
  CloseWindow;
end;

begin
  Main;
end.

