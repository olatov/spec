unit Catalogs;

{$mode unleashed}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, System.IOUtils, CsvDocument,
  Raylib, OSDMenu;

type
  TCatalogItem = record
    Name, Filename: String;
    { Both are built from CatalogDir, so a catalog found next to the binary
      rather than in the working folder needs nothing else changed. }
    function Path: String;
    function PicturePath: String;
    function HasPicture: Boolean;
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

var
  Catalog: TCatalog;
  CatalogDir: String;   { resolved at startup - see the initialization }

const
  CatalogFolder = 'catalog';
  CatalogFile = 'catalog.csv';

  { The page is one screen wide: a column of titles, then the picture. }
  CatalogListWidth = 292;
  CatalogPictureLeft = 340;
  CatalogPictureWidth = MenuWidth - MenuLeft - CatalogPictureLeft;
  { The pictures are whole emulator frames (352x288), which the emulator itself
    shows stretched to 4:3 - so that is how they are shown here too. }
  CatalogPictureHeight = CatalogPictureWidth * 3 div 4;

{$embedstr CatalogData 'catalog/catalog.csv'}

implementation

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

function TCatalogItem.HasPicture: Boolean;
begin
  Result := TFile.Exists(PicturePath);
end;

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
  CurrentItemIndex := 0;

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
      if not Name.IsEmpty and not Filename.IsEmpty and TFile.Exists(Path) then
        Inc(Count);
    end;

  SetLength(Items, Count);
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
begin
  if FPicture.id > 0 then UnloadTexture(FPicture);
  FPicture := Default(TTexture2D);
  FPictureIndex := AIndex;

  { The entries were built one per catalog title, in order, so the selection
    indexes both lists. A title without a picture leaves the frame empty. }
  if (AIndex < 0) or (AIndex > High(Catalog.Items)) then Exit;
  if not Catalog.Items[AIndex].HasPicture then Exit;

  FPicture := LoadTexture(PChar(Catalog.Items[AIndex].PicturePath));
  SetTextureFilter(FPicture, TEXTURE_FILTER_BILINEAR);
end;

procedure TCatalogMenuItem.Render(ATop: Integer);
var
  Frame: TRectangle;
begin
  if SelectedIndex <> FPictureIndex then ShowPicture(SelectedIndex);
  Catalog.CurrentItemIndex := SelectedIndex;

  RenderItems(ATop, CatalogListWidth);

  Frame := RectangleCreate(CatalogPictureLeft, ATop,
    CatalogPictureWidth, CatalogPictureHeight);

  if FPicture.id > 0 then
    DrawTexturePro(FPicture,
      RectangleCreate(0, 0, FPicture.width, FPicture.height),
      Frame, [0, 0], 0, WHITE)
  else
    DrawTextEx(Font, '(no picture)',
      [Frame.x + 12, Frame.y + (Frame.height / 2) - 10], 20, 0, GRAY);

  DrawRectangleLinesEx(Frame, 1, DARKGRAY);

  if not Warning.IsEmpty then
    DrawTextEx(Font, PChar(Warning),
      [Frame.x, Frame.y + Frame.height + 12], 20, 0, RED);
end;

function TCatalogMenuItem.Footer: String;
begin
  Result := 'ENTER - Load    ESC - Back';
end;

initialization
  { Run from the project folder the catalog is simply there; run from anywhere
    else - a launcher, a shortcut - it sits next to the binary instead. }
  CatalogDir := CatalogFolder;
  if not TFile.Exists(TPath.Combine(CatalogDir, CatalogFile)) then
    CatalogDir := TPath.Combine(GetApplicationDirectory, CatalogFolder);

  Catalog := TCatalog.Create;
  Catalog.LoadFromFile(TPath.Combine(CatalogDir, CatalogFile));
  { No list on disk: fall back to the one built into the binary, which still
    only lists the titles whose files are actually there. }
  if Catalog.IsEmpty then Catalog.LoadFromText(CatalogData);

finalization
  FreeAndNil(Catalog);

end.
