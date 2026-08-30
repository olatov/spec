program Spec;

{$mode unleashed}

{$ifdef Darwin}
  {$linkframework Cocoa}
  {$linkframework IOKit}
{$endif}

{$ifdef mswindows}
  {$apptype gui}
{$endif}

uses
  Main;

{$R *.res}

begin
  with TApplication.Create(Nil) do
  begin
    Initialize;
    Run;
    Free;
  end;
end.

