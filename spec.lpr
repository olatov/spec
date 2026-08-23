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

var
  CPU: TZ80;
  Memory: array[0..$ffff] of Byte;
  BorderColorIndex: Byte;
  Snapshot: String = '';

const
  ScanlineTStates = 224;

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
  Result := Memory[address];
  if InRange(Address, $4000, $7FFF) then CPU.cycles := CPU.cycles + 2;
end;

procedure OnMemoryWrite(context: Pointer; address: UInt16; value: UInt8); cdecl;
begin
  { WriteLn('MEMORY WRITE addr ', address, ', val ', value); }
  if address < $4000 then Exit; { ROM }
  Memory[address] := value;
  if InRange(Address, $4000, $7FFF) then CPU.cycles := CPU.cycles + 2;
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
      Data.Bits[4] := IsKeyDown(KEY_FIVE) or IsKeyDown(KEY_LEFT);
      Result := Result or Data;
    end;

    if not AMask.Bits[4] then
    begin
      { $EFFE }
      Data.Bits[0] := IsKeyDown(KEY_ZERO) or IsKeyDown(KEY_BACKSPACE);
      Data.Bits[1] := IsKeyDown(KEY_NINE);
      Data.Bits[2] := IsKeyDown(KEY_EIGHT) or IsKeyDown(KEY_RIGHT);
      Data.Bits[3] := IsKeyDown(KEY_SEVEN) or IsKeyDown(KEY_UP);
      Data.Bits[4] := IsKeyDown(KEY_SIX) or IsKeyDown(KEY_DOWN);
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
    Result.Bits[0] := IsKeyDown(KEY_RIGHT);
    Result.Bits[1] := IsKeyDown(KEY_LEFT);
    Result.Bits[2] := IsKeyDown(KEY_DOWN);
    Result.Bits[3] := IsKeyDown(KEY_UP);
    Result.Bits[4] := IsKeyDown(KEY_LEFT_ALT);
    Result.Bits[5] := IsKeyDown(KEY_SPACE);
  end;

begin
  { WriteLn('IO READ addr ', IntToHex(address, 4)); }

  if Odd(address) then
    Result := PollKempston
  else
    Result := PollKeyboard(Hi(address));
end;

procedure OnIOWrite(context: Pointer; address: UInt16; value: UInt8); cdecl;
begin
  case address.Bytes[0] of
    $FE:
      begin
        BorderColorIndex := value;
        { Writeln('IO: ', IntToHex(address, 4), ', val ', value); }
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
      DecodeBlock(16384, Stream.Size);
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

procedure Main;
var
  Target: TRenderTexture2D;
  Image: TImage;
  Video: TTexture2D;
  Colors: PColorB;
  ROM: TBytesStream;
  Row, I, Addr, Col, Offset: Integer;
  Data, Attribute: Byte;
  Palette: array[0..15] of TColorB;
  InkColorIndex, PaperColorIndex: Byte;
  Flash, FlashPhase: Boolean;
  Frames: QWord = 0;
  Paused: Boolean = False;
  Fullscreen: Boolean = False;
  AUList: TAutomationEventList;
  RunningCycles: SizeUInt = 0;
begin
  if not LoadLibrary then Halt(1);

  ROM := TBytesStream.Create;
  ROM.LoadFromFile('48.rom');
  Move(ROM.Bytes[0], Memory[0], ROM.Size);
  FreeAndNil(ROM);

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

  {
  Screen := TBytesStream.Create;
  Screen.LoadFromFile('tapper.scr');
  Move(Screen.Bytes[0], Memory[16384], Screen.Size);
  FreeAndNil(Screen);
  }

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

  SetTraceLogLevel(LOG_ERROR);

  //SetConfigFlags(FLAG_WINDOW_HIGHDPI);
  InitWindow(720, 576, 'Spec');
  SetTargetFPS(50);

  Target := LoadRenderTexture(352, 288);
  SetTextureFilter(Target.texture, TEXTURE_FILTER_BILINEAR);

  Image := GenImageColor(352, 288, BLACK);
  Video := LoadTextureFromImage(Image);

  while not WindowShouldClose do
  begin
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

      z80_run(@CPU, ScanlineTStates * 8);  { VBlank }
      z80_int(@CPU, True);
      z80_run(@CPU, 32);
      z80_int(@CPU, False);
      z80_run(@CPU, (ScanlineTStates * 56) - 32); { Top border + INT }

      ImageDrawRectangle(@Image, 0, 0, 352, 288, Palette[BorderColorIndex and $07]);

      FlashPhase := Odd(Frames div 16);

      for Row := 0 to 191 do
      begin
        Offset := 16384;
        Inc(Offset, (Row div 64) * 2048);
        Inc(Offset, ((Row mod 64) div 8) * 32);
        Inc(Offset, (Row mod 8) * 256);

        Col := 0;
        for Addr := Offset to Offset + 31 do
        begin
          Data := Memory[Addr];
          if (Col mod 8) = 0 then
          begin
            //Attribute := 7 shl 3;
            Attribute := Memory[22528 + ((Row div 8) * 32) + (Col div 8)];
            Flash := Attribute.Bits[7];
            InkColorIndex := Attribute and %111;
            InkColorIndex.Bits[3] := Attribute.Bits[6];
            PaperColorIndex := (Attribute shr 3) and %111;
            PaperColorIndex.Bits[3] := Attribute.Bits[6];

            if Flash and FlashPhase then
              Swap<Byte>(InkColorIndex, PaperColorIndex);
          end;

          for I := 7 downto 0 do
          begin
            ImageDrawPixel(@Image,
              Col + 50, Row + 50,
              Palette[if Data.Bits[I] then InkColorIndex else PaperColorIndex]);
            Inc(Col);
          end;
        end;
        z80_run(@CPU, ScanlineTStates);
      end;

      z80_run(@CPU, ScanlineTStates * 56); { Bottom border }

      Colors := LoadImageColors(Image);
      UpdateTexture(Video, Colors);
      UnloadImageColors(Colors);
    end;

    BeginTextureMode(Target);
    DrawTexture(Video, 0, 0, WHITE);
    EndTextureMode;

    BeginDrawing;
    ClearBackground(BLACK);
    DrawTexturePro(
      Target.Texture,
      RectangleCreate(0, 0, Target.texture.width, -Target.texture.height),
      RectangleCreate(0.5 * GetScreenWidth - (GetScreenHeight * 0.667), 0, GetScreenHeight * 1.333, GetScreenHeight),
      Vector2Zero, 0, WHITE);
    { DrawFPS(10, 10); }
    EndDrawing;
  end;

  UnloadImage(Image);
  UnloadTexture(Video);
  UnloadRenderTexture(Target);
  CloseWindow;
end;

begin
  Main;
end.

