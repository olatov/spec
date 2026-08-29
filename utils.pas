unit Utils;

{$mode unleashed}

interface

uses
  DynLibs;

var
  SDL_DelayPrecise: procedure(NS: UInt64); cdecl;

implementation

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

initialization
  SDL3Handle := LoadLibrary(SDL3File);
  Pointer(SDL_DelayPrecise) := GetProcAddress(SDL3Handle, 'SDL_DelayPrecise');

finalization
  UnloadLibrary(SDL3Handle);

end.

