   1 REM ====================================
   2 REM  A N A C O N D A
   3 REM  A sample program for Spec, the ZX
   4 REM  Spectrum 48K emulator.
   5 REM  Original work, MIT licence.
   6 REM ====================================
   7 REM
   8 REM  The interpreter searches the variable
   9 REM  area from the start, so the variables
  10 REM  the main loop touches most are created
  11 REM  first. This alone is worth about a
  12 REM  fifth of the frame time.
  20 LET x=0: LET y=0: LET k=0: LET n=0: LET t=0: LET g=0: LET h=0: LET c=0
  30 LET d=0: LET s=0: LET f=0: LET l=0: LET w=0: LET e=0
  40 LET m=250: DIM p(m): DIM q(m)
  50 GO SUB 9000: REM  define the apple
  60 GO SUB 8000: REM  title screen
  70 RANDOMIZE
  80 GO SUB 7000: REM  lay out a new game
 100 REM  --- read the keys ---
 110 LET c=CODE INKEY$: IF c=0 THEN GO TO 200
 120 IF c>96 THEN LET c=c-32
 130 IF (c=81 OR c=55) AND d<>2 THEN LET d=1: LET g=0: LET h=-1
 140 IF (c=65 OR c=54) AND d<>1 THEN LET d=2: LET g=0: LET h=1
 150 IF (c=79 OR c=53) AND d<>4 THEN LET d=3: LET g=-1: LET h=0
 160 IF (c=80 OR c=56) AND d<>3 THEN LET d=4: LET g=1: LET h=0
 170 IF c=32 THEN GO SUB 5000
 200 REM  --- move the anaconda ---
 210 REM  The old head turns into body and the
 220 REM  tail cell is freed before the new head
 230 REM  is tested, so following your own tail
 240 REM  round a corner is legal.
 250 PRINT AT y,x; PAPER 4; BRIGHT 0;" ";AT q(t),p(t); PAPER 0;" "
 260 LET x=x+g: LET y=y+h: LET k=ATTR (y,x)
 270 IF k<>0 AND k<>6 THEN GO TO 400
 280 PRINT AT y,x; PAPER 4; BRIGHT 1;" "
 290 LET n=n+1: IF n>m THEN LET n=1
 300 LET p(n)=x: LET q(n)=y
 310 IF k=6 THEN GO TO 340
 320 LET t=t+1: IF t>m THEN LET t=1
 330 IF w>0 THEN FOR i=1 TO w: NEXT i
 335 GO TO 110
 340 REM  --- an apple was eaten ---
 350 PRINT AT q(t),p(t); PAPER 4;" ": REM  the tail stays put
 360 LET s=s+10: LET f=f+1: LET l=l+1: BEEP .008,24: BEEP .008,31
 370 PRINT AT 0,6; INK 6;s
 380 IF l>=m-1 THEN GO TO 460
 390 IF f/2=INT (f/2) AND w>0 THEN LET w=w-1
 395 GO SUB 6000: GO TO 110
 400 REM  --- the anaconda crashed ---
 410 LET o=x-g: LET v=y-h: REM  the last cell it filled
 420 FOR i=1 TO 10: PRINT AT v,o; PAPER 2; BRIGHT 1;" ": BEEP .02,22-i*2: PRINT AT v,o; PAPER 0;" ": NEXT i
 430 PRINT AT 10,6; PAPER 2; INK 7; BRIGHT 1;"  G A M E   O V E R  "
 440 GO TO 470
 460 PRINT AT 10,6; PAPER 4; INK 0; BRIGHT 1;"   Y O U   W I N !   "
 470 IF s>e THEN LET e=s: PRINT AT 12,8; INK 6; FLASH 1;" NEW HIGH SCORE! "
 480 PRINT AT 14,3; INK 7;"Press SPACE to play again"
 490 IF INKEY$<>"" THEN GO TO 490
 495 IF INKEY$<>" " THEN GO TO 495
 499 GO TO 80
5000 REM  --- pause ---
5010 PRINT AT 0,12; INK 7; FLASH 1;"PAUSED"
5020 IF INKEY$<>"" THEN GO TO 5020
5030 IF INKEY$<>" " THEN GO TO 5030
5040 IF INKEY$<>"" THEN GO TO 5040
5050 PRINT AT 0,12;"      ": RETURN
6000 REM  --- drop a new apple ---
6010 LET b=1+INT (RND*29): LET r=2+INT (RND*19)
6020 IF ATTR (r,b)<>0 THEN GO TO 6010
6030 PRINT AT r,b; INK 6; BRIGHT 0; PAPER 0;CHR$ 144
6040 RETURN
7000 REM  --- set up a new game ---
7010 BORDER 0: PAPER 0: INK 0: BRIGHT 0: FLASH 0: CLS
7020 LET s=0: LET f=0: LET w=8
7030 PRINT AT 0,0; INK 6;"SCORE ";s;AT 0,20;"HI ";e
7040 FOR i=0 TO 30: PRINT AT 1,i; PAPER 5;" ";AT 21,i; PAPER 5;" ": NEXT i
7050 FOR i=2 TO 20: PRINT AT i,0; PAPER 5;" ";AT i,30; PAPER 5;" ": NEXT i
7060 LET x=15: LET y=11: LET g=1: LET h=0: LET d=4
7070 LET l=4: LET n=l: LET t=1
7080 FOR i=1 TO l: LET p(i)=x-l+i: LET q(i)=y: PRINT AT y,p(i); PAPER 4;" ": NEXT i
7090 PRINT AT y,x; PAPER 4; BRIGHT 1;" "
7095 GO SUB 6000: RETURN
8000 REM  --- title screen ---
8010 BORDER 0: PAPER 0: INK 7: BRIGHT 0: FLASH 0: CLS
8020 PRINT AT 2,6; PAPER 4; INK 0; BRIGHT 1;"  A N A C O N D A  "
8030 PRINT AT 4,5; INK 5;"for the Spec emulator"
8040 PRINT AT 7,2; INK 7;"Eat the apples "; INK 6;CHR$ 144; INK 7;" and grow,"
8050 PRINT AT 8,2;"but never bite a wall or your"
8060 PRINT AT 9,2;"own tail."
8070 PRINT AT 12,8; INK 5;"Q"; INK 7;" / "; INK 5;"7"; INK 7;"  up"
8080 PRINT AT 13,8; INK 5;"A"; INK 7;" / "; INK 5;"6"; INK 7;"  down"
8090 PRINT AT 14,8; INK 5;"O"; INK 7;" / "; INK 5;"5"; INK 7;"  left"
8100 PRINT AT 15,8; INK 5;"P"; INK 7;" / "; INK 5;"8"; INK 7;"  right"
8110 PRINT AT 16,8; INK 5;"SPACE"; INK 7;"  pause"
8120 PRINT AT 18,2; INK 4;"5678 also suits the emulator's"
8130 PRINT AT 19,2; INK 4;"Cursor joystick mode."
8140 FOR i=15 TO 22: PRINT AT 21,i; PAPER 4;" ": NEXT i
8150 PRINT AT 21,23; PAPER 4; BRIGHT 1;" ";AT 21,25; INK 6; PAPER 0;CHR$ 144
8160 PRINT AT 21,1; INK 6; FLASH 1;"Press a key"
8170 IF INKEY$<>"" THEN GO TO 8170
8180 IF INKEY$="" THEN GO TO 8180
8190 IF INKEY$<>"" THEN GO TO 8190
8195 RETURN
9000 REM  --- the apple, UDG "A" ---
9010 LET u=USR "a": RESTORE 9030
9020 FOR i=0 TO 7: READ b: POKE u+i,b: NEXT i
9030 DATA 24,48,124,254,254,254,124,56
9040 RETURN
