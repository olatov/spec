program Spec;

{$mode unleashed}

{$ifdef Darwin}
  {$linkframework Cocoa}
  {$linkframework IOKit}
{$endif}

uses
  Main, Utils;

begin
  with TApplication.Create(Nil) do
  begin
    Initialize;
    Run;
    Free;
  end;
end.

