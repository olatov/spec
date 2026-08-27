unit OSDMenu;

{$mode unleashed}

interface

uses
  Classes, SysUtils, FGL,
  Raylib;

type
  TMenu = class;
  TMenuNotify = reference to procedure(Sender: TMenu);
  TMenuItem = class;
  TMenuItemNotify = reference to procedure(Sender: TMenuItem);

  TMenuItem = class
  private
    FOnActivate: TMenuItemNotify;
    FParent: TMenuItem;
    function GetMenu: TMenu; virtual;
    function GetSelectedItem: TMenuItem;
  public
    Text: String;
    Value: String;
    Active: Boolean;
    SelectedIndex: Integer;
    Items: TFPGObjectList<TMenuItem>;
    OnApply: TMenuItemNotify;
    OnEscape: TMenuItemNotify;
    property Parent: TMenuItem read FParent;
    property Menu: TMenu read GetMenu;
    property SelectedItem: TMenuItem read GetSelectedItem;
    function AddItem(AText: String; AValue: String = ''; AOnApply: TMenuItemNotify =
      nil): TMenuItem;
    procedure Apply;
    procedure Escape;
    procedure Next;
    procedure Previous;
    constructor Create(AParent: TMenuItem = Nil); virtual;
    destructor Destroy; override;
  end;

  TRootMenuItem = class(TMenuItem)
    FMenu: TMenu;
    constructor Create(AParent: TMenu);
    function GetMenu: TMenu; override;
  end;

  TMenu = class(TComponent)
  private
    FTarget: TRenderTexture;
    FVisible: Boolean;
    function GetTexture: TTexture2D;
    procedure SetVisible(AValue: Boolean);
  public
    Root: TRootMenuItem;
    OnClose: TMenuNotify;
    procedure HandleInput;
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
    procedure Close;
    procedure Render;
    property Texture: TTexture2D read GetTexture;
    property Visible: Boolean read FVisible write SetVisible;
  end;

implementation

function TMenuItem.GetSelectedItem: TMenuItem;
begin
  Result := if SelectedIndex < Items.Count
    then Items[SelectedIndex]
    else Nil;
end;

function TMenuItem.GetMenu: TMenu;
begin
  Result := Parent.Menu;
end;

function TMenuItem.AddItem(AText: String; AValue: String; AOnApply: TMenuItemNotify = Nil): TMenuItem;
begin
  Result := TMenuItem.Create(Self);
  Result.Text := AText;
  Result.Value := AValue;
  Result.OnApply := AOnApply;
  Items.Add(Result);
end;

procedure TMenuItem.Apply;
begin
  Active := True;
  if Assigned(OnApply) then OnApply(Self);
  {if Assigned(SelectedItem) then SelectedItem.Apply;}
end;

procedure TMenuItem.Escape;
begin
  Active := False;
end;

procedure TMenuItem.Next;
begin
  if Items.Count = 0 then Exit;
  SelectedIndex := (SelectedIndex + 1) mod Items.Count;
end;

procedure TMenuItem.Previous;
begin
  if Items.Count = 0 then Exit;
  SelectedIndex := (SelectedIndex - 1) mod Items.Count;
  if SelectedIndex < 0 then SelectedIndex := Items.Count - 1;
end;

constructor TMenuItem.Create(AParent: TMenuItem);
begin
  Items := TFPGObjectList<TMenuItem>.Create;
  FParent := AParent;
end;

destructor TMenuItem.Destroy;
begin
  inherited Destroy;
  FreeAndNil(Items);
end;

constructor TRootMenuItem.Create(AParent: TMenu);
begin
  Items := TFPGObjectList<TMenuItem>.Create;
  FMenu := AParent;
end;

function TRootMenuItem.GetMenu: TMenu;
begin
  Result := FMenu;
end;

procedure TMenu.SetVisible(AValue: Boolean);
begin
  if FVisible = AValue then Exit;
  FVisible := AValue;
end;

procedure TMenu.HandleInput;
begin
  if IsKeyPressed(KEY_UP) then Root.Previous;
  if IsKeyPressed(KEY_DOWN) then Root.Next;
  if IsKeyPressed(KEY_ENTER) then Root.SelectedItem.Apply;
  if IsKeyPressed(KEY_ESCAPE) then
  begin
    Root.SelectedItem.Escape;
    if not Root.SelectedItem.Active and Assigned(OnClose) then
      OnClose(Self);
  end;
end;

function TMenu.GetTexture: TTexture2D;
begin
  Result := FTarget.texture;
end;

constructor TMenu.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  Root := TRootMenuItem.Create(Self);
  Root.OnEscape := procedure(Sender: TMenuItem)
    begin
      if Assigned(OnClose) then OnClose(Self);
    end;

  FTarget := LoadRenderTexture(640, 480);
  SetTextureFilter(FTarget.texture, TEXTURE_FILTER_BILINEAR);
end;

destructor TMenu.Destroy;
begin
  inherited Destroy;
  FreeAndNil(Root);
  UnloadRenderTexture(FTarget);
end;

procedure TMenu.Close;
begin
  if Assigned(OnClose) then OnClose(Self);
end;

procedure TMenu.Render;
var
  Item: TMenuItem;
  I: Integer;
  Text: String;
  IsSelected: Boolean;
begin
  BeginTextureMode(FTarget);

  ClearBackground(NAVY);

  DrawText(PChar('>> SPEC <<'), 24, 6, 36, AQUA);

  for I := 0 to Root.Items.Count - 1 do
  begin
    Item := Root.Items[I];
    IsSelected := Item = Root.SelectedItem;

    Text := Item.Text;
    if not Item.Value.IsEmpty then
      Text := Text + ': ' + Item.Value;

    DrawText(PChar(Text), 24, 64 + I * 32, 24,
      if IsSelected then Yellow else ORANGE);
  end;

  DrawText('ESC - close menu', 24, 440, 20, YELLOW);

  EndTextureMode;
end;

end.

