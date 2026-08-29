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

const
  { None of these are in FPC's Windows unit. ProcessPowerThrottling is the
    fifth member of PROCESS_INFORMATION_CLASS; the flag values are the ones
    processthreadsapi.h gives them. }
  ProcessPowerThrottling                           = 4;
  PROCESS_POWER_THROTTLING_CURRENT_VERSION         = 1;
  PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION = $4;

  TimerPeriod = 1;   { milliseconds asked of timeBeginPeriod }

type
  TProcessPowerThrottlingState = record
    Version: ULONG;
    ControlMask: ULONG;
    StateMask: ULONG;
  end;

function SetProcessInformation(hProcess: THandle; ProcessInformationClass: DWORD;
  ProcessInformation: Pointer; ProcessInformationSize: DWORD): BOOL; stdcall;
  external 'kernel32' name 'SetProcessInformation';

procedure Delay(ASecs: Double); inline;
begin
  Sleep(Trunc(ASecs * 1000));
end;

{ Windows 11 stops honouring a process's timer resolution request once its
  window is fully occluded or minimised and the process is silent, at which
  point Sleep() falls back towards the ~15.6 ms system tick and every frame
  overshoots its deadline. Audio playing is enough to stay exempt, so this
  only bites while muted - which is precisely when the audio breaking up
  would go unnoticed and the video stuttering would not. }
procedure KeepTimerResolution;
var
  State: TProcessPowerThrottlingState;
begin
  FillChar(State, SizeOf(State), 0);
  State.Version := PROCESS_POWER_THROTTLING_CURRENT_VERSION;

  { ControlMask picks the mechanism and StateMask says whether it is on, so a
    zero StateMask here reads as "do not ignore my timer resolution requests".
    Naming the flag in both masks would switch the throttling on instead. }
  State.ControlMask := PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION;
  State.StateMask := 0;

  { Fails on Windows 10 and earlier, where the flag does not exist - leaving
    the behaviour those versions have anyway, so the result is not worth
    acting on. }
  SetProcessInformation(GetCurrentProcess, ProcessPowerThrottling,
    @State, SizeOf(State));
end;

initialization
  KeepTimerResolution;
  timeBeginPeriod(TimerPeriod);

finalization
  timeEndPeriod(TimerPeriod);
{$else}
  {$fail 'Unsupported platform'}
{$endif}

end.

