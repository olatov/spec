unit Catalogs;

{$mode unleashed}
{$modeswitch advancedrecords}

interface

uses
  {$ifdef mswindows} Windows, {$endif}
  Classes, SysUtils, System.IOUtils, CsvDocument, Math,
  Raylib, OSDMenu;

const
  DefaultItemIndex = 0;

type
  TCatalogItem = record
    Name, Filename: String;
    { Both are built from CatalogDir, so a catalog found next to the binary
      rather than in the working folder needs nothing else changed. }
    function Path: String;
    function PicturePath: String;
    function HasPicture: Boolean;
    function GetPictureStream: TMemoryStream;
    function GetContentStream: TMemoryStream;
  end;

  TCatalog = class
  private
    function GetCount: Integer;
    function GetCurrentItem: TCatalogItem;
    function GetIsEmpty: Boolean;
  public
    Items: TArray<TCatalogItem>;
    CurrentItemIndex: Integer;
    property CurrentItem: TCatalogItem read GetCurrentItem;
    procedure Next;
    procedure Prev;
    property Count: Integer read GetCount;
    property IsEmpty: Boolean read GetIsEmpty;
    procedure LoadFromStream(AStream: TStream);
    procedure LoadFromText(const AText: String);
    procedure LoadFromFile(AFilename: String);
    {$ifdef EMBED_CATALOG}
      procedure LoadEmbedded;
    {$endif}
  end;

  { The Catalog page: the titles down the left, the selected title's screen
    beside them. Navigation, scrolling and ENTER are the base class's - all
    this adds is the picture, which is loaded once per selection rather than
    per frame. }
  TCatalogMenuItem = class(TMenuItem)
  private
    FPicture: TTexture2D;
    FPictureIndex: Integer;
    procedure ShowPicture(AIndex: Integer);
  public
    procedure Render(ATop: Integer); override;
    function Footer: String; override;
    constructor Create(AParent: TMenuItem = Nil); override;
    destructor Destroy; override;
  end;

{ Adds the Catalog page to AParent, one entry per title. Each entry carries the
  title's full path in its Data, so AOnOpen is the same handler for all of them
  and this unit stays out of the business of loading files. }
function AddCatalogPage(AParent: TMenuItem; AOnOpen: TMenuItemNotify): TCatalogMenuItem;

{ Finds the catalog and loads it. APath is [Files] CatalogPath from spec.conf;
  an empty one means "look in the usual places".

  This is a call rather than something the unit does to itself on the way up,
  because the answer depends on the settings and there is no saying which unit
  initializes first. }
procedure LoadCatalog(const APath: String);

var
  Catalog: TCatalog;
  CatalogDir: String;   { resolved at startup - see the initialization }

const
  {$ifndef EMBED_CATALOG}
    CatalogFolder = 'catalog';
    CatalogFile = 'catalog.csv';
  {$endif}

  { The page is one screen wide: a column of titles, then the picture. }
  CatalogListWidth = 292;
  CatalogPictureLeft = 340;
  CatalogPictureWidth = MenuWidth - MenuLeft - CatalogPictureLeft;
  { The pictures are whole emulator frames (352x288), which the emulator itself
    shows stretched to 4:3 - so that is how they are shown here too. }
  CatalogPictureHeight = CatalogPictureWidth * 3 div 4;
  CatalogNameSize = 20;

implementation

{$ifdef EMBED_CATALOG}
  {$R catalog/catalog.rc}
{$endif}

{ The menu's font carries plain ASCII and nothing else, so a title typed in a
  word processor - which quietly turns ' into a curly quote - would otherwise
  read "BC?s Quest for Tires". Only the punctuation that has an ASCII twin is
  worth folding; anything else is left for the font to deal with. }
function FoldPunctuation(const AText: String): String;
const
  Curly: array[0..7] of String = (
    #$E2#$80#$98, #$E2#$80#$99,                 { ' ' }
    #$E2#$80#$9C, #$E2#$80#$9D,                 { " " }
    #$E2#$80#$93, #$E2#$80#$94,                 { en and em dash }
    #$E2#$80#$A6, #$C2#$A0);                    { ellipsis, no-break space }
  Plain: array[0..7] of String = (
    '''', '''', '"', '"', '-', '-', '...', ' ');
var
  I: Integer;
begin
  Result := AText;
  for I := 0 to High(Curly) do
    Result := Result.Replace(Curly[I], Plain[I], [rfReplaceAll]);
end;

function TCatalogItem.Path: String;
begin
  Result := TPath.Combine(CatalogDir, Filename);
end;

function TCatalogItem.PicturePath: String;
begin
  Result := TPath.Combine(CatalogDir,
    TPath.GetFileNameWithoutExtension(Filename) + '.png');
end;

{$ifdef EMBED_CATALOG}
function TCatalogItem.HasPicture: Boolean;
var
  Stream: TStream;
begin
  Stream := autofree GetPictureStream;
  Result := Assigned(Stream);
end;
{$else}
function TCatalogItem.HasPicture: Boolean;
begin
  Result := TFile.Exists(PicturePath);
end;
{$endif}

{$ifdef EMBED_CATALOG}
function TCatalogItem.GetPictureStream: TMemoryStream;
var
  ResStream: TResourceStream;
begin
  Result := Nil;
  try
    ResStream := autofree TResourceStream.Create(HINSTANCE, 'PICTURE_' + Filename, RT_RCDATA);
  except
    on E: EResNotFound do Exit;
  end;

  Result := TMemoryStream.Create;
  Result.CopyFrom(ResStream, ResStream.Size);
end;
{$else}
function TCatalogItem.GetPictureStream: TMemoryStream;
begin
  Result := TMemoryStream.Create;
  Result.LoadFromFile(PicturePath);
end;
{$endif}

{$ifdef EMBED_CATALOG}
function TCatalogItem.GetContentStream: TMemoryStream;
var
  ResStream: TResourceStream;
begin
  ResStream := autofree TResourceStream.Create(HINSTANCE, 'GAME_' + Filename, RT_RCDATA);
  Result := TMemoryStream.Create;
  Result.CopyFrom(ResStream, ResStream.Size);
end;
{$else}
function TCatalogItem.GetContentStream: TMemoryStream;
begin
  Result := TMemoryStream.Create;
  Result.LoadFromFile(Path);
end;
{$endif}

function TCatalog.GetCount: Integer;
begin
  Result := Length(Items);
end;

function TCatalog.GetCurrentItem: TCatalogItem;
begin
  if CurrentItemIndex <= High(Items) then
    Result := Items[CurrentItemIndex];
end;

function TCatalog.GetIsEmpty: Boolean;
begin
  Result := Count = 0;
end;

procedure TCatalog.Next;
begin
  if Count > 0 then
    CurrentItemIndex := (CurrentItemIndex + 1) mod Count;
end;

procedure TCatalog.Prev;
begin
  if Count > 0 then Dec(CurrentItemIndex);
  if CurrentItemIndex < 0 then CurrentItemIndex := High(Items);
end;

{ Row 0 names the columns; every row after it is "title,file". A title whose
  file is not there is left out rather than listed and then failing to load -
  which is also what makes a list that ships without its files read as empty,
  and so leaves the emulator booting the way it always did. }
procedure TCatalog.LoadFromStream(AStream: TStream);
var
  Doc: TCSVDocument;
  Row, Count: Integer;
begin
  Items := Nil;

  Doc := autofree TCSVDocument.Create;
  Doc.LoadFromStream(AStream);
  if Doc.RowCount < 2 then Exit;

  SetLength(Items, Doc.RowCount - 1);
  Count := 0;

  for Row := 1 to Doc.RowCount - 1 do
    with Items[Count] do
    begin
      Name := FoldPunctuation(Doc.Cells[0, Row].Trim);
      Filename := Doc.Cells[1, Row].Trim;
      if not Name.IsEmpty and not Filename.IsEmpty
        {$ifndef EMBED_CATALOG}
          and TFile.Exists(Path)
        {$endif}
        then Inc(Count);
    end;

  SetLength(Items, Count);
  CurrentItemIndex := Min(DefaultItemIndex, High(Items));
end;

procedure TCatalog.LoadFromText(const AText: String);
var
  Stream: TStringStream;
begin
  Stream := autofree TStringStream.Create(AText);
  LoadFromStream(Stream);
end;

procedure TCatalog.LoadFromFile(AFilename: String);
var
  Stream: TFileStream;
begin
  if not TFile.Exists(AFilename) then Exit;
  Stream := autofree TFile.OpenRead(AFilename);
  LoadFromStream(Stream);
end;

{$ifdef EMBED_CATALOG}
procedure TCatalog.LoadEmbedded;
var
  Stream: TResourceStream;
begin
  Stream := autofree TResourceStream.Create(HINSTANCE, 'CATALOG', RT_RCDATA);
  LoadFromStream(Stream);
end;
{$endif}

function AddCatalogPage(AParent: TMenuItem; AOnOpen: TMenuItemNotify): TCatalogMenuItem;
var
  Item: TCatalogItem;
begin
  Result := TCatalogMenuItem.Create(AParent);
  Result.Font := AParent.Font;
  Result.Text := 'Catalog';
  AParent.Items.Add(Result);

  for Item in Catalog.Items do
    Result.AddItem(Item.Name, '', AOnOpen).Data := Item.Path;

  { Reopening the page comes back to the title left on last time. }
  Result.SelectedIndex := Catalog.CurrentItemIndex;
end;

constructor TCatalogMenuItem.Create(AParent: TMenuItem);
begin
  inherited Create(AParent);
  FPictureIndex := -1;   { no selection has been drawn yet }
end;

destructor TCatalogMenuItem.Destroy;
begin
  if FPicture.id > 0 then UnloadTexture(FPicture);
  inherited Destroy;
end;

procedure TCatalogMenuItem.ShowPicture(AIndex: Integer);
var
  Stream: TMemoryStream;
  Buffer: TImage;
begin
  if FPicture.id > 0 then UnloadTexture(FPicture);
  FPicture := Default(TTexture2D);
  FPictureIndex := AIndex;

  { A title without a picture - and a page with nothing selected - leaves the
    frame empty. }
  if (AIndex < 0) or (AIndex > High(Catalog.Items)) then Exit;
  if not Catalog.Items[AIndex].HasPicture then Exit;

  {FPicture := LoadTexture(PChar(Catalog.Items[AIndex].PicturePath));}

  Stream := autofree Catalog.Items[AIndex].GetPictureStream;
  Buffer := LoadImageFromMemory('.png', Stream.Memory, Stream.Size);
  FPicture := LoadTextureFromImage(Buffer);
  UnloadImage(Buffer);

  GenTextureMipmaps(@FPicture);
  SetTextureFilter(FPicture, TEXTURE_FILTER_TRILINEAR);
end;

procedure TCatalogMenuItem.Render(ATop: Integer);
var
  Frame: TRectangle;
  Line: String;
  Y: Single;
  Index: Integer;
const
  Crop = 24;
begin
  { The entries were built one per catalog title, in order, so an entry's place
    in the page's own list is its place in the catalog. Its place in the shown
    list is not, once a filter has taken titles out of the middle - so the
    picture is looked up by the entry, never by the selection index. }
  Index := Items.IndexOf(SelectedItem);
  if Index <> FPictureIndex then ShowPicture(Index);
  if Index >= 0 then Catalog.CurrentItemIndex := Index;

  RenderItems(ATop, CatalogListWidth);

  Frame := RectangleCreate(CatalogPictureLeft, ATop,
    CatalogPictureWidth, CatalogPictureHeight);

  if FPicture.id > 0 then
    DrawTexturePro(FPicture,
      RectangleCreate(Crop * 1.33, Crop, FPicture.width - (2.66 * Crop), FPicture.height - (2 * Crop)),
      Frame, [0, 0], 0, WHITE)
  else
    DrawTextEx(Font, '(no picture)',
      [Frame.x + 12, Frame.y + (Frame.height / 2) - 10], 20, 0, GRAY);

  DrawRectangleLinesEx(Frame, 1, DARKGRAY);

  { The column of titles is only as wide as it is, so a long one is cut short
    there - under the picture it is spelled out in full, wrapped rather than
    trimmed. }
  Y := Frame.y + Frame.height + 12;

  if Assigned(SelectedItem) then
    for Line in WrapText(Font, SelectedItem.Text, CatalogNameSize, Frame.width) do
    begin
      DrawTextEx(Font, PChar(Line), [Frame.x, Y], CatalogNameSize, 0, YELLOW);
      Y := Y + CatalogNameSize + 4;
    end;

  if not Warning.IsEmpty then
    DrawTextEx(Font, PChar(Warning), [Frame.x, Y + 8], 20, 0, RED);
end;

function TCatalogMenuItem.Footer: String;
begin
  Result := 'ENTER - Load    ESC - Back';
end;

{$ifndef EMBED_CATALOG}
{ Run from the project folder the catalog is simply there; run from anywhere
  else - a launcher, a shortcut - it sits next to the binary instead.

  A macOS bundle puts two more places in the way, because the binary is buried
  in spec.app/Contents/MacOS and "next to the binary" is somewhere no player
  will ever open. What they see is the bundle, so a catalog they can add to
  goes beside that, three levels up. One shipped inside the app goes in
  Contents/Resources, where the signature covers it - which is also why it is
  looked at last: sealed means the player cannot add a game to it, so anything
  they put outside should win. }
function ResolveCatalogDir(const AConfigured: String): String;
var
  Candidates: array of String;
  Candidate, AppDir: String;

  procedure Consider(const APath: String);
  begin
    Insert(APath, Candidates, Integer.MaxValue);
  end;

begin
  { A folder named in spec.conf is taken at its word and nothing else is tried:
    a path with a typo in it should show up as an empty catalog, not as a
    different one quietly loading in its place. }
  if not AConfigured.IsEmpty then Exit(AConfigured);

  Candidates := Nil;
  AppDir := ExcludeTrailingPathDelimiter(GetApplicationDirectory);

  Consider(CatalogFolder);
  Consider(TPath.Combine(AppDir, CatalogFolder));

  {$ifdef darwin}
  { Only when the binary really is inside a bundle - the same three levels up
    from a loose one would land on the root of the disk. }
  if TPath.GetFileName(AppDir) = 'MacOS' then
  begin
    Consider(TPath.Combine(
      ExpandFileName(TPath.Combine(AppDir, '../../..')), CatalogFolder));
    Consider(TPath.Combine(
      ExpandFileName(TPath.Combine(AppDir, '../Resources')), CatalogFolder));
  end;
  {$endif}

  for Candidate in Candidates do
    if TFile.Exists(TPath.Combine(Candidate, CatalogFile)) then Exit(Candidate);

  { Nothing anywhere. The working folder is the answer the emulator has always
    given, and LoadFromFile finding nothing there leaves the catalog empty -
    which the menu already knows how to show. }
  Result := CatalogFolder;
end;
{$endif}

procedure LoadCatalog(const APath: String);
begin
  {$ifdef EMBED_CATALOG}
    Catalog.LoadEmbedded;
  {$else}
    { Everything else the catalog reads - the games, the screenshots - is built
      from CatalogDir, so this is the only place that has to know. }
    CatalogDir := ResolveCatalogDir(APath);
    Catalog.LoadFromFile(TPath.Combine(CatalogDir, CatalogFile));
  {$endif}
end;

initialization
  Catalog := TCatalog.Create;

finalization
  FreeAndNil(Catalog);

end.
