program Spec;

{$mode unleashed}

{$ifdef Darwin}
  {$linkframework Cocoa}
  {$linkframework IOKit}
{$endif}

{$if defined(mswindows) and not defined(AUDIO_DEBUG)}
  {$apptype gui}
{$endif}

uses
  Main;

begin
  with TApplication.Create(Nil) do
  begin
    Initialize;
    Run;
    Free;
  end;
end.

