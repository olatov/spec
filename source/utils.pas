unit Utils;

{$mode unleashed}

interface

uses
  Raylib;

var
  Delay: procedure(ASecs: Double); cdecl; = @Raylib.WaitTime;

{ Where the emulator writes: spec.conf, snapshots, taped programs and
  screenshots, unless [Files] SavePath sends the snapshots elsewhere.

  On Windows and Linux that is the folder it was started from, which is what
  makes a copied folder a self-contained install. macOS gives an .app no such
  folder: Finder launches it with the root directory as its working directory,
  and writing beside the bundle would break the signature it was sealed with,
  so the writes go where the system keeps a user's per-application files.
  SPEC_DATA_DIR overrides both. }
function UserDataDir: String;

{ Expands a leading ~ in a path typed into spec.conf. Nothing else is touched:
  a relative path stays relative, so 'catalog' still means what it says. }
function ExpandUserPath(const APath: String): String;

implementation

uses
  {$ifdef mswindows} Windows, MMSystem, {$endif}
  SysUtils, System.IOUtils,
  AppSettings;

function ExpandUserPath(const APath: String): String;
var
  Home: String;
begin
  Result := APath;
  if Result = '' then Exit;
  if Result[1] <> '~' then Exit;

  { ~ on its own, or ~/something. Resolving ~someone-else is the shell's job
    and guessing at it would only turn a typo into a wrong folder. }
  if (Length(Result) > 1) and (Result[2] <> '/') then Exit;

  Home := GetEnvironmentVariable('HOME');
  {$ifdef mswindows}
  if Home = '' then Home := GetEnvironmentVariable('USERPROFILE');
  {$endif}
  if Home = '' then Exit;

  Result := SetDirSeparators(Home + Copy(Result, 2, Length(Result)));
end;

var
  { Settled once: the answer cannot change while the emulator runs, and the
    menu asks for it often enough that a stat per frame would be a waste. }
  FUserDataDir: String = '';

function UserDataDir: String;
begin
  if not FUserDataDir.IsEmpty then Exit(FUserDataDir);

  FUserDataDir := SysUtils.GetEnvironmentVariable('SPEC_DATA_DIR');

  {$ifdef darwin}
  if FUserDataDir.IsEmpty then
    FUserDataDir := TPath.Combine(SysUtils.GetEnvironmentVariable('HOME'),
      'Library/Application Support/spec');
  {$endif}

  { Nothing to fall back on but the working directory - which is what the
    other platforms use anyway, and is at least always there. }
  if FUserDataDir.IsEmpty or not ForceDirectories(FUserDataDir) then
    FUserDataDir := GetCurrentDir;

  Result := FUserDataDir;
end;

{$ifdef mswindows}
const
  { None of these are in FPC's Windows unit. ProcessPowerThrottling is the
    fifth member of PROCESS_INFORMATION_CLASS; the flag values are the ones
    processthreadsapi.h gives them. }
  ProcessPowerThrottling                           = 4;
  PROCESS_POWER_THROTTLING_CURRENT_VERSION         = 1;
  PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION = $4;

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

{ raylib asks for 1 ms timer resolution itself - InitTimer calls
  timeBeginPeriod and ClosePlatform gives it back - and that is all its
  WaitTime needs, since on Windows it is a Sleep() followed by a short busy
  wait, and a Sleep that returns past the deadline is one the busy wait
  cannot take back.

  What raylib does not do is this. Windows 11 stops honouring the resolution
  request once the window is fully occluded or minimised and the process is
  silent, at which point Sleep() falls back towards the ~15.6 ms system tick
  and overshoots by most of a frame - far enough that Run writes the schedule
  off and starts again rather than making it up. Audio playing is enough to
  stay exempt, so it only bites while muted, which is precisely when the
  audio breaking up would go unnoticed and the video stuttering would not. }
procedure KeepTimerResolution;
var
  State: TProcessPowerThrottlingState;
begin
  State := Default(TProcessPowerThrottlingState);
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

procedure DelaySleep(ASeconds: Double); cdecl;
begin
  Sleep(Trunc(ASeconds * 1000));
end;

initialization
  {$ifdef mswindows}
    Pointer(SetProcessInformation) :=
      GetProcAddress(GetModuleHandle('kernel32'), 'SetProcessInformation');
    KeepTimerResolution;
  {$endif}

  if Settings.System.DelayDriver = ddSleep then
  begin
    Delay := @DelaySleep;
    {$ifdef mswindows}
      timeBeginPeriod(1);
    {$endif}
  end;

finalization
  {$ifdef mswindows}
    if Settings.System.DelayDriver = ddSleep then
      timeEndPeriod(1);
  {$endif}
end.

