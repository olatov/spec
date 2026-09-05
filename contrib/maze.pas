(**
 * M A Z E   R U N N E R
 *
 * A sample program for Spec, the ZX Spectrum 48K emulator.
 * Original work, MIT licence -- no copyrighted material.
 *
 * Collect every gem to open the exit, then reach it before the
 * clock runs out.  Each level is a freshly generated maze.
 *
 * Build the tape image with:
 *   pasta --zx48 --tap --opt --release maze.pas
 *)
program Maze;

{$ifdef SYS_CPM}
  {$error ZX Spectrum 48K required.}
{$endif}

const
  MazeW  = 15;                  { maze width, in cells                   }
  MazeH  = 10;                  { maze height, in cells                  }
  GridW  = 31;                  { character columns = 2 * MazeW + 1      }
  GridH  = 21;                  { character rows    = 2 * MazeH + 1      }
  Cells  = 150;                 { MazeW * MazeH                          }
  ExitX  = 30;                  { the far corner cell, = 2 * MazeW       }
  ExitY  = 20;                  {                        2 * MazeH       }

  { Tiles.  The grid holds what is underneath the player, so stepping
    off a square simply repaints whatever the grid still says is there. }
  TWall  = 0;
  TFloor = 1;
  TGem   = 2;
  TExit  = 3;

  { Keyboard half-rows.  Reading the matrix through Port[] instead of
    ReadKey avoids the ROM's auto-repeat delay, so a held key gives
    smooth movement, and it costs a single IN per half-row.  A bit is
    LOW while its key is down. }
  KQWERT = $FBFE;               { Q W E R T = bits 0..4 }
  KASDFG = $FDFE;               { A S D F G }
  KPOIUY = $DFFE;               { P O I U Y }
  K09876 = $EFFE;               { 0 9 8 7 6 }
  K12345 = $F7FE;               { 1 2 3 4 5 }
  KSPACE = $7FFE;               { SPACE SYMSHIFT M N B }

var
  Grid: array[1..GridW, 1..GridH] of Byte;
  Seen: array[0..14, 0..9] of Boolean;
  Trail: array[0..149] of Byte;

  PX, PY: Integer;              { player, in grid coordinates }
  Level, Score, HiScore: Integer;
  GemTotal, GemLeft: Integer;
  Allow, TimeLeft: Integer;
  StartF: Real;
  Dirty, Quit, Escaped: Boolean;

(* True while the key selected by mask M in half-row P is held down. *)
function Held(P, M: Integer): Boolean;
begin
  Held := (Port[P] and M) = 0;
end;

(* Blocks until nothing is pressed, so a key that started the level
   is not read again as a move. *)
procedure Drain;
begin
  while (Port[KQWERT] and 31) <> 31 do ;
  while (Port[KASDFG] and 31) <> 31 do ;
  while (Port[KPOIUY] and 31) <> 31 do ;
  while (Port[K09876] and 31) <> 31 do ;
  while (Port[K12345] and 31) <> 31 do ;
  while (Port[KSPACE] and 31) <> 31 do ;
end;

(* Waits for a genuinely fresh key press.  The game reads the matrix
   directly and never calls ReadKey while playing, so the ROM has been
   quietly latching key presses in FLAGS the whole time.  Anything
   already pending has to be thrown away, or the "press any key"
   screens dismiss themselves instantly. *)
procedure WaitKey;
begin
  Drain;
  while KeyPressed do ReadKey;
  repeat until KeyPressed;
  ReadKey;
  Drain;
end;

procedure DrawStatus;
begin
  GotoXY(1, 1);
  TextBackground(Black);
  TextColor(Cyan);
  Write('L', Level:2, '  GEM', GemTotal - GemLeft:3, '/', GemTotal:2,
        '  T', TimeLeft:4, '  ', Score:6);
end;

(* Paints one grid square.  Screen row is grid row + 1: row 1 is status. *)
procedure PutTile(X, Y: Integer);
var
  T: Byte;
begin
  GotoXY(X, Y + 1);
  T := Grid[X, Y];
  case T of
    TWall: begin
             TextBackground(Blue); Write(' ');
           end;
    TGem:  begin
             TextBackground(Black); TextColor(Yellow); Write('*');
           end;
    TExit: begin
             if GemLeft = 0 then TextBackground(Green)
                            else TextBackground(Red);
             Write(' ');
           end;
    TFloor: begin
              TextBackground(Black); Write(' ');
            end;
  end;
end;

procedure PutPlayer;
begin
  GotoXY(PX, PY + 1);
  TextBackground(Black);
  TextColor(White);
  Write('@');
end;

(* Recursive backtracker, done iteratively: the Z80 stack is only 4K,
   and 150 cells of recursion would not be worth the risk. *)
procedure Generate;
var
  X, Y, SP, Cur, CX, CY, NCX, NCY, N: Integer;
  Dirs: array[0..3] of Integer;
begin
  for X := 1 to GridW do
    for Y := 1 to GridH do
      Grid[X, Y] := TWall;

  FillChar(Seen, SizeOf(Seen), 0);

  Seen[0, 0] := True;
  Grid[2, 2] := TFloor;
  SP := 0;
  Trail[0] := 0;

  while SP >= 0 do
  begin
    Cur := Trail[SP];
    CX := Cur mod MazeW;
    CY := Cur div MazeW;

    N := 0;
    if (CX > 0) and not Seen[CX - 1, CY] then begin Dirs[N] := 0; Inc(N) end;
    if (CX < MazeW - 1) and not Seen[CX + 1, CY] then begin Dirs[N] := 1; Inc(N) end;
    if (CY > 0) and not Seen[CX, CY - 1] then begin Dirs[N] := 2; Inc(N) end;
    if (CY < MazeH - 1) and not Seen[CX, CY + 1] then begin Dirs[N] := 3; Inc(N) end;

    if N = 0 then Dec(SP)
    else
    begin
      NCX := CX;
      NCY := CY;
      case Dirs[Random(N)] of
        0: Dec(NCX);
        1: Inc(NCX);
        2: Dec(NCY);
        3: Inc(NCY);
      end;

      { the wall between two cells is their midpoint }
      Grid[CX + NCX + 2, CY + NCY + 2] := TFloor;
      Grid[2 * NCX + 2, 2 * NCY + 2] := TFloor;

      Seen[NCX, NCY] := True;
      Inc(SP);
      Trail[SP] := NCY * MazeW + NCX;
    end;
  end;

  { the exit sits in the far corner, the player starts in the near one }
  Grid[ExitX, ExitY] := TExit;
  PX := 2;
  PY := 2;

  { scatter the gems over plain floor only }
  N := 0;
  while N < GemTotal do
  begin
    X := 2 * Random(MazeW) + 2;
    Y := 2 * Random(MazeH) + 2;
    if (Grid[X, Y] = TFloor) and not ((X = PX) and (Y = PY)) then
    begin
      Grid[X, Y] := TGem;
      Inc(N);
    end;
  end;

  GemLeft := GemTotal;
end;

(* One GotoXY per row, then a straight run of writes: the cursor
   advances by itself, and the attribute only changes on a tile change. *)
procedure DrawMaze;
var
  X, Y, T, Last: Integer;
begin
  for Y := 1 to GridH do
  begin
    GotoXY(1, Y + 1);
    Last := -1;
    for X := 1 to GridW do
    begin
      T := Grid[X, Y];
      if T <> Last then
      begin
        case T of
          TWall:  begin TextBackground(Blue); TextColor(Blue) end;
          TGem:   begin TextBackground(Black); TextColor(Yellow) end;
          TExit:  begin TextBackground(Red); TextColor(Black) end;
          TFloor: begin TextBackground(Black); TextColor(White) end;
        end;
        Last := T;
      end;
      if T = TGem then Write('*') else Write(' ');
    end;
  end;
  PutPlayer;
end;

procedure Banner(Y: Integer; Ink, Paper: Integer; S: String);
begin
  GotoXY((32 - Length(S)) div 2, Y);
  TextBackground(Paper);
  TextColor(Ink);
  Write(S);
  TextBackground(Black);
end;

procedure Title;
begin
  Border(Black);
  TextBackground(Black);
  TextColor(White);
  ClrScr;

  Banner(2, Black, Cyan, '  M A Z E   R U N N E R  ');
  Banner(4, Yellow, Black, 'for the Spec emulator');

  GotoXY(3, 7);  TextColor(White);
  Write('Collect every ');
  TextColor(Yellow); Write('*');
  TextColor(White); Write(' to open the');
  GotoXY(3, 8);  Write('exit, then reach it before');
  GotoXY(3, 9);  Write('the clock runs out.');

  GotoXY(6, 12); TextColor(Cyan); Write('Q');
  TextColor(White); Write(' / '); TextColor(Cyan); Write('7');
  TextColor(White); Write('   up');
  GotoXY(6, 13); TextColor(Cyan); Write('A');
  TextColor(White); Write(' / '); TextColor(Cyan); Write('6');
  TextColor(White); Write('   down');
  GotoXY(6, 14); TextColor(Cyan); Write('O');
  TextColor(White); Write(' / '); TextColor(Cyan); Write('5');
  TextColor(White); Write('   left');
  GotoXY(6, 15); TextColor(Cyan); Write('P');
  TextColor(White); Write(' / '); TextColor(Cyan); Write('8');
  TextColor(White); Write('   right');
  GotoXY(6, 16); TextColor(Cyan); Write('SPACE');
  TextColor(White); Write('   give up');

  GotoXY(2, 18); TextColor(Green);
  Write('5678 also suits the emulator''s');
  GotoXY(2, 19);
  Write('Cursor joystick mode.');

  Banner(21, Yellow, Black, 'Press any key');

  WaitKey;
end;

procedure PlayLevel;
var
  DX, DY, NX, NY, T, Now: Integer;
begin
  TextBackground(Black);
  TextColor(White);
  ClrScr;

  Generate;
  DrawMaze;
  TimeLeft := Allow;
  DrawStatus;

  StartF := Frames;
  Escaped := False;
  Dirty := False;

  repeat
    DX := 0;
    DY := 0;
    if Held(KQWERT, 1) or Held(K09876, 8) then DY := -1
    else if Held(KASDFG, 1) or Held(K09876, 16) then DY := 1
    else if Held(KPOIUY, 2) or Held(K12345, 16) then DX := -1
    else if Held(KPOIUY, 1) or Held(K09876, 4) then DX := 1;

    if Held(KSPACE, 1) then Quit := True;

    if (DX <> 0) or (DY <> 0) then
    begin
      NX := PX + DX;
      NY := PY + DY;
      if Grid[NX, NY] <> TWall then
      begin
        PutTile(PX, PY);
        PX := NX;
        PY := NY;
        T := Grid[PX, PY];

        if T = TGem then
        begin
          Grid[PX, PY] := TFloor;
          Dec(GemLeft);
          Inc(Score, 10 * Level);
          Dirty := True;
          Beep(0.008, 24);
          if GemLeft = 0 then
          begin
            PutTile(ExitX, ExitY);   { the exit turns green }
            Beep(0.03, 12);
            Beep(0.03, 24);
          end;
        end
        else if (T = TExit) and (GemLeft = 0) then Escaped := True;

        PutPlayer;
      end;
    end;

    Now := Allow - Trunc((Frames - StartF) / 50);
    if Now <> TimeLeft then
    begin
      TimeLeft := Now;
      Dirty := True;
    end;

    if Dirty then
    begin
      DrawStatus;
      Dirty := False;
    end;

    Delay(60);
  until Escaped or Quit or (TimeLeft <= 0);
end;

procedure Outcome;
var
  I: Integer;
begin
  if Escaped then
  begin
    Inc(Score, TimeLeft * 2);
    DrawStatus;
    Banner(11, White, Green, '   L E V E L   C L E A R   ');
    Banner(13, Yellow, Black, 'Time bonus');
    for I := 1 to 6 do Beep(0.05, I * 3);
    Inc(Level);
    if GemTotal < 15 then Inc(GemTotal, 2);
    if Allow > 45 then Dec(Allow, 8);
  end
  else
  begin
    Banner(11, White, Red, '    G A M E   O V E R    ');
    for I := 6 downto 1 do Beep(0.06, I * 3 - 12);
  end;

  if Score > HiScore then
  begin
    HiScore := Score;
    Banner(15, Yellow, Black, ' NEW HIGH SCORE! ');
  end;

  Banner(17, White, Black, 'Press any key');
  WaitKey;
end;

begin
  Randomize;
  HiScore := 0;

  repeat
    Title;

    Level := 1;
    Score := 0;
    GemTotal := 5;
    Allow := 90;
    Quit := False;

    repeat
      PlayLevel;
      Outcome;
    until Quit or (TimeLeft <= 0);
  until False;
end.
