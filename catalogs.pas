unit Catalogs;

{$mode unleashed}
{$modeswitch advancedrecords}

interface

uses
  Classes, SysUtils, System.IOUtils, CsvDocument,
  Raylib;

type
  TCatalogItem = record
    Name, Filename: String;
    function GetContents: TStream;
    function GetPicture: TStream;
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
    procedure LoadFromFile(AFilename: String);
  end;

var
  Catalog: TCatalog;

const
  CatalogPath= 'catalog/catalog.csv';

{$embedstr CatalogData 'catalog/catalog.csv'}

implementation

function TCatalogItem.GetContents: TStream;
var
  Path: String;
begin
  Path := TPath.Combine(CatalogPath, Filename);
  Result := if TFile.Exists(Path) then TFile.OpenRead(Path) else Nil;
end;

function TCatalogItem.GetPicture: TStream;
var
  Path: String;
begin
  Path := TPath.Combine(CatalogPath, TPath.GetFileNameWithoutExtension(Filename) + '.png');
  Result := if TFile.Exists(Path) then TFile.OpenRead(Path) else Nil;
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

procedure TCatalog.LoadFromStream(AStream: TStream);
var
  Doc: TCSVDocument;
  I: Integer;
begin
  Doc := autofree TCSVDocument.Create;
  Doc.LoadFromStream(AStream);
  if Doc.RowCount = 0 then Exit;

  SetLength(Items, Doc.RowCount - 1);
  for I := 1 to Doc.RowCount - 1 do
    with Items[I - 1] do
    begin
      Name := Doc.Cells[0, I];
      Filename := Doc.Cells[0, I];
    end;

  CurrentItemIndex := 0;
end;

procedure TCatalog.LoadFromFile(AFilename: String);
var
  Stream: TFileStream;
begin
  Stream := autofree TFile.OpenRead(AFilename);
  LoadFromStream(Stream);
end;

initialization
  Catalog := TCatalog.Create;
  Catalog.LoadFromFile(CatalogPath);

finalization
  FreeAndNil(Catalog);

end.

