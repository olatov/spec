unit Utils;

{$mode unleashed}

interface

uses
  Raylib;

var
  Delay: procedure(ASecs: Double); cdecl; = @Raylib.WaitTime;

implementation

{$ifdef mswindows}
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
  State := Default(TProcessPowerThrottlingState);
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

initialization
  Pointer(SetProcessInformation) :=
    GetProcAddress(GetModuleHandle('kernel32'), 'SetProcessInformation');
  KeepTimerResolution;
{$endif}

end.

