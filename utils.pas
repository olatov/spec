unit Utils;

{$mode unleashed}

interface

type
  TDelayProc = procedure(ASecs: Double);

var
  Delay: TDelayProc;

implementation

uses
  {$if defined(mswindows)}
    Windows, MMSystem,
  {$elseif defined(unix)}
    BaseUnix,
  {$endif}
  SysUtils, DynLibs,
  Raylib,
  AppSettings;

var
  SDL3Handle: TLibHandle = NilHandle;
  SDL_DelayFunc: procedure(NS: UInt64); cdecl; = Nil;

const
  SDL3File =
    {$if defined(mswindows)}
      'SDL3.dll'
    {$elseif defined(darwin)}
      'libSDL3.dylib'
    {$else}
      'libSDL3.so'
    {$endif};

procedure DelayRaylib(ASecs: Double);
begin
  Raylib.WaitTime(ASecs);
end;

procedure DelaySDL3(ASecs: Double);
begin
  SDL_DelayFunc(Trunc(ASecs * 1.0e+9));
end;

{$ifdef unix}
procedure DelayNanoSleep(ASecs: Double); inline;
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
{$endif}

{$ifdef mswindows}
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

  TSetProcessInformation = function(hProcess: THandle;
    ProcessInformationClass: DWORD; ProcessInformation: Pointer;
    ProcessInformationSize: DWORD): BOOL; stdcall;

var
  { SetProcessInformation only exists in kernel32 from Windows 8 on. A
    load-time import would stop the process starting at all on Windows 7 and
    earlier, so it is resolved by hand and left nil where absent. }
  SetProcessInformation: TSetProcessInformation;

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

  { The flag itself only lands on Windows 11; on Windows 8..10 the call just
    returns an error, and on Windows 7 SetProcessInformation is nil. Either
    way the older behaviour is what those versions have anyway, so the result
    is not worth acting on. }
  if Assigned(SetProcessInformation) then
    SetProcessInformation(GetCurrentProcess, ProcessPowerThrottling,
      @State, SizeOf(State));
end;
{$endif}

procedure DelaySleep(ASecs: Double); inline;
begin
  Sleep(Trunc(ASecs * 1000));
end;

procedure LoadSDL3;
begin
  SDL3Handle := DynLibs.LoadLibrary(SDL3File);
  if SDL3Handle = NilHandle then
    raise Exception.CreateFmt('%s could not be loaded', [SDL3File]);

  Pointer(SDL_DelayFunc) := Dynlibs.GetProcAddress(SDL3Handle,
    if Settings.System.DelayDriver = ddSDL3DelayNS
      then 'SDL_DelayNS'
      else 'SDL_DelayPrecise');
end;

procedure UnloadSDL3;
begin
  UnloadLibrary(SDL3Handle);
end;

initialization
  Delay := @DelaySleep;
  case Settings.System.DelayDriver of
    ddDefault:
      begin
        {$if defined(mswindows)}
          Pointer(SetProcessInformation) :=
            GetProcAddress(GetModuleHandle('kernel32'), 'SetProcessInformation');
          KeepTimerResolution;
          timeBeginPeriod(TimerPeriod);
        {$elseif defined(unix)}
          Delay := @DelayNanoSleep;
        {$else}
          Delay := @DelaySleep;
        {$endif}
      end;

    ddRaylib:
      Delay := @DelayRaylib;

    ddSDL3DelayNS, ddSDl3DelayPrecise:
      begin
        LoadSDL3;
        Delay := @DelaySDL3;
      end;
  end;

finalization
  case Settings.System.DelayDriver of
    ddDefault:
      begin
        {$ifdef mswindows}
          timeEndPeriod(TimerPeriod);
        {$endif}
      end;

    ddSDL3DelayNS, ddSDL3DelayPrecise:
      UnloadSDL3;
  end;

end.

