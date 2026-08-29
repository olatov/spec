unit Utils;

{$mode unleashed}

interface

procedure Delay(ASecs: Double); inline;

implementation

{$if defined(USE_SDL3_DELAYNS) or defined(USE_SDL3_DELAYPRECISE)}
uses
  DynLibs;

var
  SDL3Handle: TLibHandle;

const
  SDL3File =
    {$if defined(mswindows)}
      'SDL3.dll'
    {$elseif defined(darwin)}
      'libSDL3.dylib'
    {$else}
      'libSDL3.so'
    {$endif};

  SDLDelayFuncName =
    {$if defined(USE_SDL3_DELAYPRECISE)}
      'SDL_DelayPrecise'
    {$else}
      'SDL_DelayNS'
    {$endif};

var
  SDL_DelayFunc: procedure(NS: UInt64); cdecl;

procedure Delay(ASecs: Double); inline;
begin
  SDL_DelayFunc(Trunc(ASecs * 1.0e+9));
end;

initialization
  SDL3Handle := LoadLibrary(SDL3File);
  Pointer(SDL_DelayFunc) := GetProcAddress(SDL3Handle, SDLDelayFuncName);

finalization
  UnloadLibrary(SDL3Handle);

{$elseif defined(unix)}
uses
  BaseUnix, SysUtils;

procedure Delay(ASecs: Double); inline;
var
  TS: array[1..2] of TTimeSpec;
  Requested, Remaining: PTimeSpec;
  Result: CInt;
  Interrupted: Boolean;
  NS: UInt64;
begin
  Requested := @TS[1];
  Remaining := @TS[2];

  { tv_nsec has to stay under a second or nanosleep rejects the whole call
    with EINVAL. }
  NS := Trunc(ASecs * 1.0e+9);
  Requested^.tv_sec := NS div 1000000000;
  Requested^.tv_nsec := NS mod 1000000000;

  { A signal cuts the sleep short and leaves the balance in Remaining, so the two
    buffers swap roles and the balance is slept off. Any other failure repeats
    identically however often it is retried - and leaves Remaining untouched - so it
    ends the loop rather than spinning on it forever. }
  repeat
    Result := FPnanosleep(Requested, Remaining);
    Interrupted := (Result = -1) and (fpgeterrno = ESysEINTR);
    if Interrupted then Swap<ptimespec>(Requested, Remaining);
  until not Interrupted;
end;
{$elseif defined(mswindows)}
uses
  Windows, MMSystem;

procedure Delay(ASecs: Double); inline;
begin
  if timeBeginPeriod(1) = 0 then
  try
    Windows.Sleep(Trunc(ASecs * 1000));
  finally
    timeEndPeriod(1);
  end;
end;
{$else}
  {$fail 'Unsupported platform'}
{$endif}

end.

