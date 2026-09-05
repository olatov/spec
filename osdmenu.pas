unit OSDMenu;

{$mode unleashed}

interface

uses
  Classes, SysUtils, Math, FGL,
  Raylib, Inputs;

type
  TMenu = class;
  TMenuItem = class;
  TEditMenuItem = class;
  TFileMenuItem = class;
  TBindMenuItem = class;
  TMenuNotify = reference to procedure(ASender: TMenu; AQuit: Boolean);
  TMenuItemNotify = reference to procedure(ASender: TMenuItem);
  TMenuEditNotify = reference to procedure(ASender: TEditMenuItem);
  TMenuBrowseNotify = reference to procedure(ASender: TFileMenuItem);
  TMenuBindNotify = reference to procedure(ASender: TBindMenuItem;
    const ASource: TInputSource);
  TMenuItemList = TFPGObjectList<TMenuItem>;

  { One entry in the menu, and - for items that have children or are a dialog -
    also the page that entry opens. The menu shows exactly one item's page at a
    time (TMenu.Current); input and drawing are dispatched to it, so a new kind
    of page is a new descendant rather than another branch in the menu code. }
  TMenuItem = class
  private
    FParent: TMenuItem;
    FItems: TMenuItemList;
    FFilteredItems: TMenuItemList;
    FFilter: String;
    function GetMenu: TMenu; virtual;
    function GetSelectedItem: TMenuItem;
    procedure SetFilter(AValue: String);
  public
    Font: TFont;
    Text: String;
    Value: String;         { shown after the text, for settings and defaults }
    Data: String;          { the owner's payload - never drawn }
    Warning: String;       { drawn by the pages that have somewhere to put it }
    SelectedIndex: Integer;
    OnApply: TMenuItemNotify;
    property Items: TMenuItemList read FItems;
    property Filter: String read FFilter write SetFilter;
    property FilteredItems: TMenuItemList read FFilteredItems;
    property Parent: TMenuItem read FParent;
    property Menu: TMenu read GetMenu;
    property SelectedItem: TMenuItem read GetSelectedItem;
    function AddItem(AText: String; AValue: String = ''; AOnApply: TMenuItemNotify =
      nil): TMenuItem;
    function AddEdit(AText: String; APrompt: String; AOnAccept: TMenuEditNotify):
      TEditMenuItem;
    function AddBrowser(AText: String; APath: String; AOnBrowse: TMenuBrowseNotify):
      TFileMenuItem;
    function AddBind(AText: String; APrompt: String; AOnCapture: TMenuBindNotify):
      TBindMenuItem;
    { Chosen from the parent page: plain items just run OnApply, items that
      have children take over the screen. }
    procedure Apply; virtual;
    { The four below run only while this item owns the screen. AfterInput is
      where a page does work its own items could not do safely from inside
      their handlers. }
    procedure HandleInput; virtual;
    procedure AfterInput; virtual;
    procedure Render(ATop: Integer); virtual;
    { Draws this page's own items as a column AWidth wide - which is the whole
      page for most of them, and less for a page that keeps room beside the
      list. }
    procedure RenderItems(ATop, AWidth: Integer);
    function Footer: String; virtual;
    procedure Next;
    procedure Previous;
    procedure PageUp;
    procedure PageDown;
    procedure Home;
    procedure End_;
    function Find(APrefix: String; AFrom: Integer = 0): Integer;
    constructor Create(AParent: TMenuItem = Nil); virtual;
    destructor Destroy; override;
  end;

  { A single-line text field, for naming things (snapshot files, so far).
    Value is the edited text. OnChange fires on open and after every keystroke,
    which is where the owner refreshes Warning and Notes; OnAccept fires on
    ENTER and is free to close the menu. }
  TEditMenuItem = class(TMenuItem)
  public
    Prompt: String;
    Notes: TStringArray;
    MaxLength: Integer;
    OnAccept: TMenuEditNotify;
    OnChange: TMenuEditNotify;
    procedure Apply; override;
    procedure Changed;
    procedure HandleInput; override;
    procedure Render(ATop: Integer); override;
    function Footer: String; override;
    constructor Create(AParent: TMenuItem = Nil); override;
  end;

  { A list page whose entries are built from a folder, rebuilt whenever it
    opens or the folder changes. What counts as an entry is the owner's call
    (OnBrowse fills the list, and puts each entry's path in its Data); this
    class owns only which folder is being shown - and the timing, since an
    entry that navigates is itself in the list about to be thrown away, so a
    rebuild asked for from an entry waits until its handler has returned. }
  TFileMenuItem = class(TMenuItem)
  private
    FPendingPath: String;
    FNavigating: Boolean;
    procedure Rebuild(const APath: String);
  public
    Path: String;
    OnBrowse: TMenuBrowseNotify;
    procedure Apply; override;
    procedure Browse(const APath: String);
    procedure AfterInput; override;
    procedure Render(ATop: Integer); override;
  end;

  { A page that waits for one press - a key, a pad button or a stick pushed -
    and hands it to its owner: how a binding is re-taught. Value is the binding
    as it stands, which the owner refreshes from OnCapture. ESC leaves it
    alone; DEL clears it, since an input that means "nothing" is the one thing
    no press can say. }
  TBindMenuItem = class(TMenuItem)
  public
    Prompt: String;
    OnCapture: TMenuBindNotify;
    procedure Apply; override;
    procedure HandleInput; override;
    procedure Render(ATop: Integer); override;
    function Footer: String; override;
  end;

  TRootMenuItem = class(TMenuItem)
    FMenu: TMenu;
    constructor Create(AParent: TMenu);
    function GetMenu: TMenu; override;
  end;

  TMenu = class(TComponent)
  private
    FTarget: TRenderTexture;
    FCurrent: TMenuItem;
    FCloseRequested: Boolean;
    FQuitRequested: Boolean;
    function GetTexture: TTexture2D;
  public
    Font: TFont;
    Root: TRootMenuItem;
    OnClose: TMenuNotify;
    procedure HandleInput;
    constructor Create(AOwner: TComponent); override;
    constructor Create(AOwner: TComponent; AFont: TFont);
    destructor Destroy; override;
    { Both are deferred to the end of HandleInput: the owner frees the menu
      from OnClose, so nothing may run inside an item afterwards. }
    procedure Close;
    procedure Back;
    procedure Show(AItem: TMenuItem);
    procedure Render;
    property Current: TMenuItem read FCurrent;
    property Texture: TTexture2D read GetTexture;
  end;

{ AText trimmed to what fits AWidth at ASize, with an ellipsis standing in for
  whatever had to go. }
function FitText(AFont: TFont; const AText: String; ASize, AWidth: Single): String;
{ AText broken at spaces into lines that each fit AWidth at ASize. A single
  word too wide for the column has nowhere to break, so it is trimmed instead. }
function WrapText(AFont: TFont; const AText: String; ASize, AWidth: Single): TStringArray;

const
  { The size of the texture the menu is drawn into, and so the room every page
    has to lay itself out in. }
  MenuWidth = 640;
  MenuHeight = 480;
  MenuLeft = 24;
  MenuLineHeight = 30;
  MenuVisibleItems = 12;
  MenuTextSize = 24;
  Copyright = '(c)2026 @olatov';

implementation

function FitText(AFont: TFont; const AText: String; ASize, AWidth: Single): String;
const
  Ellipsis = '...';
begin
  Result := AText;
  if MeasureTextEx(AFont, PChar(Result), ASize, 0).x <= AWidth then Exit;

  while not Result.IsEmpty and
    (MeasureTextEx(AFont, PChar(Result + Ellipsis), ASize, 0).x > AWidth) do
    SetLength(Result, Length(Result) - 1);

  Result := Result.TrimRight + Ellipsis;
end;

function WrapText(AFont: TFont; const AText: String; ASize, AWidth: Single): TStringArray;
var
  Line: String = '';
  Count: Integer = 0;
  Token: String;

  { Closes the line being built, trimmed in case it holds a single word that
    was too wide to break. }
  procedure Emit;
  begin
    if Line.IsEmpty then Exit;
    SetLength(Result, Count + 1);
    Result[Count] := FitText(AFont, Line, ASize, AWidth);
    Inc(Count);
    Line := '';
  end;

begin
  Result := Nil;

  for Token in AText.Split([' ']) do
  begin
    if Token.IsEmpty then Continue;

    if Line.IsEmpty then
      Line := Token
    else if MeasureTextEx(AFont, PChar(Line + ' ' + Token), ASize, 0).x > AWidth then
    begin
      Emit;
      Line := Token;
    end
    else
      Line := Line + ' ' + Token;
  end;

  Emit;
end;

function TMenuItem.GetSelectedItem: TMenuItem;
begin
  Result := if InRange(SelectedIndex, 0, FilteredItems.Count - 1)
    then FilteredItems[SelectedIndex]
    else Nil;
end;

{ Rebuilds the shown list from the whole one. An empty filter matches
  everything, so the two lists hold the same items in the same order and every
  page that has no filter behaves as it did before there was one. }
procedure TMenuItem.SetFilter(AValue: String);
var
  I: Integer;
  Selected: TMenuItem;
  Param: String;
begin
  FFilter := AValue;
  { The selection belongs to an item, not to a place in the list - typing a
    filter must not slide it onto whichever title lands at that place. }
  Selected := SelectedItem;

  FFilteredItems.Clear;
  Param := AValue.Trim;
  for I := 0 to Items.Count - 1 do
    if FFilter.IsEmpty or Items[I].Text.Contains(Param, True) then
      FilteredItems.Add(Items[I]);

  { A selection filtered away leaves the first match selected. }
  SelectedIndex := Max(FilteredItems.IndexOf(Selected), 0);
end;

function TMenuItem.GetMenu: TMenu;
begin
  Result := Parent.Menu;
end;

function TMenuItem.AddItem(AText: String; AValue: String; AOnApply: TMenuItemNotify = Nil): TMenuItem;
begin
  Result := TMenuItem.Create(Self);
  Result.Font := Font;
  Result.Text := AText;
  Result.Value := AValue;
  Result.OnApply := AOnApply;
  Items.Add(Result);
  Filter := '';
end;

function TMenuItem.AddEdit(AText: String; APrompt: String; AOnAccept: TMenuEditNotify): TEditMenuItem;
begin
  Result := TEditMenuItem.Create(Self);
  Result.Font := Font;
  Result.Text := AText;
  Result.Prompt := APrompt;
  Result.OnAccept := AOnAccept;
  Items.Add(Result);
  Filter := '';
end;

function TMenuItem.AddBrowser(AText: String; APath: String; AOnBrowse: TMenuBrowseNotify): TFileMenuItem;
begin
  Result := TFileMenuItem.Create(Self);
  Result.Font := Font;
  Result.Text := AText;
  Result.Path := APath;
  Result.OnBrowse := AOnBrowse;
  Items.Add(Result);
  Filter := '';
end;

function TMenuItem.AddBind(AText: String; APrompt: String; AOnCapture: TMenuBindNotify): TBindMenuItem;
begin
  Result := TBindMenuItem.Create(Self);
  Result.Font := Font;
  Result.Text := AText;
  Result.Prompt := APrompt;
  Result.OnCapture := AOnCapture;
  Items.Add(Result);
  Filter := '';
end;

procedure TMenuItem.Apply;
begin
  if Assigned(OnApply) then OnApply(Self);
  { OnApply may have filled the list (a browser building its entries), so the
    decision to open a page is made after it has run. }
  if FilteredItems.Count > 0 then Menu.Show(Self);
end;

procedure TMenuItem.HandleInput;
var
  Key: TKeyboardKey;
begin
  if IsKeyPressed(KEY_UP) or IsKeyPressedRepeat(KEY_UP)
    or TPadNavigation.Pressed(paUp) then Previous;
  if IsKeyPressed(KEY_DOWN) or IsKeyPressedRepeat(KEY_DOWN)
    or TPadNavigation.Pressed(paDown) then Next;
  if IsKeyPressed(KEY_PAGE_UP) or IsKeyPressedRepeat(KEY_PAGE_UP)
    or TPadNavigation.Pressed(paPageUp) then PageUp;
  if IsKeyPressed(KEY_PAGE_DOWN) or IsKeyPressedRepeat(KEY_PAGE_DOWN)
    or TPadNavigation.Pressed(paPageDown) then PageDown;
  if IsKeyPressed(KEY_HOME) then Home;
  if IsKeyPressed(KEY_END) then End_;

  Key := GetKeyPressed;
  case Key of
    KEY_ZERO..KEY_NINE, KEY_A..KEY_Z, KEY_PERIOD, KEY_SPACE:
      Filter := Filter + Char(Key - KEY_A + Ord('A'));

    KEY_BACKSPACE:
      Filter := LeftStr(Filter, Max(Length(Filter) - 1, 0));
  end;

  if IsKeyPressed(KEY_ESCAPE) or TPadNavigation.Pressed(paBack) then
  begin
    Menu.Back;
    Exit;
  end;
  { Last, and nothing after it: the item may close the menu, which frees
    everything here. }
  if (IsKeyPressed(KEY_ENTER) or TPadNavigation.Pressed(paSelect))
    and Assigned(SelectedItem) then SelectedItem.Apply;
end;

procedure TMenuItem.AfterInput;
begin
end;

procedure TMenuItem.Render(ATop: Integer);
begin
  RenderItems(ATop, MenuWidth - (2 * MenuLeft));
end;

procedure TMenuItem.RenderItems(ATop, AWidth: Integer);
var
  Item: TMenuItem;
  I, First: Integer;
  Line, Counter: String;
  Room, CounterWidth: Single;
begin
  Room := AWidth;

  if not Filter.IsEmpty then
    DrawTextEx(Font, PChar(Filter),
      [490 - (MeasureText(PChar(Filter), 24) * 0.5), 12],
      24, 0, YELLOW);

  { A list too long to show at once is labelled with the position in it. The
    label shares the top line with an item, so every line gives up the room it
    takes rather than only the one that would collide with it. }
  if FilteredItems.Count > MenuVisibleItems then
  begin
    Counter := $'{SelectedIndex + 1}/{FilteredItems.Count}';
    CounterWidth := MeasureTextEx(Font, PChar(Counter), 20, 0).x;
    Room := Room - CounterWidth - 12;
    DrawTextEx(Font, PChar(Counter),
      [MenuLeft + AWidth - CounterWidth, ATop], 20, 0, SKYBLUE);
  end;

  { Scroll the window of items only when the selection would leave it, so
    short lists never move. }
  First := Max(0, Min(SelectedIndex - (MenuVisibleItems div 2),
    FilteredItems.Count - MenuVisibleItems));

  for I := First to Min(First + MenuVisibleItems, FilteredItems.Count) - 1 do
  begin
    Item := FilteredItems[I];

    Line := Item.Text;
    if not Item.Value.IsEmpty then
      Line := Line + ': ' + Item.Value;

    DrawTextEx(Font, PChar(FitText(Font, Line, MenuTextSize, Room)),
      [MenuLeft, ATop + ((I - First) * MenuLineHeight)],
      MenuTextSize, 0, if Item = SelectedItem then YELLOW else ORANGE);
  end;
end;

function TMenuItem.Footer: String;
begin
  Result := if Assigned(Parent) then 'ESC - Back' else 'ESC again - Close';
end;

procedure TMenuItem.Next;
begin
  if FilteredItems.Count = 0 then Exit;
  SelectedIndex := (SelectedIndex + 1) mod FilteredItems.Count;
end;

procedure TMenuItem.Previous;
begin
  if FilteredItems.Count = 0 then Exit;
  SelectedIndex := (SelectedIndex - 1) mod FilteredItems.Count;
  if SelectedIndex < 0 then SelectedIndex := FilteredItems.Count - 1;
end;

procedure TMenuItem.PageUp;
begin
  if FilteredItems.Count = 0 then Exit;
  SelectedIndex := Max(SelectedIndex - 10, 0);
end;

procedure TMenuItem.PageDown;
begin
  if FilteredItems.Count = 0 then Exit;
  SelectedIndex := Min(SelectedIndex + 10, FilteredItems.Count - 1);
end;

procedure TMenuItem.Home;
begin
  SelectedIndex := 0;
end;

procedure TMenuItem.End_;
begin
  SelectedIndex := FilteredItems.Count - 1;
end;

function TMenuItem.Find(APrefix: String; AFrom: Integer): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := AFrom to FilteredItems.Count - 1 do
    if FilteredItems[I].Text.StartsWith(APrefix, True) then Exit(I);
end;

constructor TMenuItem.Create(AParent: TMenuItem);
begin
  FItems := TMenuItemList.Create(True);
  FFilteredItems := TMenuItemList.Create(False);
  FParent := AParent;
end;

destructor TMenuItem.Destroy;
begin
  FreeAndNil(FItems);
  FreeAndNil(FFilteredItems);
  inherited Destroy;  
end;

constructor TEditMenuItem.Create(AParent: TMenuItem);
begin
  inherited Create(AParent);
  MaxLength := 32;
end;

procedure TEditMenuItem.Apply;
begin
  if Assigned(OnApply) then OnApply(Self);   { the owner seeds Value here }
  Changed;
  Menu.Show(Self);
  { Drop anything typed before the field opened, including the key that
    opened it. }
  while GetCharPressed <> 0 do ;
end;

procedure TEditMenuItem.Changed;
begin
  Warning := '';
  if Assigned(OnChange) then OnChange(Self);
end;

procedure TEditMenuItem.HandleInput;
var
  Codepoint: Integer;
  Edited: Boolean = False;
begin
  Codepoint := GetCharPressed;
  while Codepoint <> 0 do
  begin
    { The default font is ASCII only, and file names have no business
      carrying control characters. }
    if InRange(Codepoint, 32, 126) and (Length(Value) < MaxLength) then
    begin
      Value := Value + Chr(Codepoint);
      Edited := True;
    end;
    Codepoint := GetCharPressed;
  end;

  if (IsKeyPressed(KEY_BACKSPACE) or IsKeyPressedRepeat(KEY_BACKSPACE))
    and not Value.IsEmpty then
  begin
    SetLength(Value, Length(Value) - 1);
    Edited := True;
  end;

  if Edited then Changed;

  { There is no typing on a pad, but a page with no way out of it is worse
    than one that cannot be filled in. }
  if IsKeyPressed(KEY_ESCAPE) or TPadNavigation.Pressed(paBack) then
  begin
    Menu.Back;
    Exit;
  end;

  if IsKeyPressed(KEY_ENTER) then
  begin
    { OnAccept may close the menu and take this item with it - nothing below. }
    if Assigned(OnAccept) then OnAccept(Self) else Menu.Back;
    Exit;
  end;
end;

procedure TEditMenuItem.Render(ATop: Integer);
var
  I: Integer;
  Caret: String;
begin
  DrawTextEx(Font, PChar(Prompt), [MenuLeft, ATop], 24, 0, ORANGE);

  DrawRectangleLines(MenuLeft, ATop + 34, 592, 46, AQUA);
  Caret := if Frac(GetTime * 2) < 0.5 then '_' else '';
  DrawTextEx(Font, PChar(Value + Caret),
    [MenuLeft + 12, ATop + 46], 28, 0, YELLOW);

  if not Warning.IsEmpty then
    DrawTextEx(Font, PChar(Warning), [MenuLeft, ATop + 92], 20, 0, RED);

  for I := 0 to High(Notes) do
    DrawTextEx(Font, PChar(Notes[I]),
      [MenuLeft, ATop + 124 + (I * 26)], 20, 0, SKYBLUE);
end;

function TEditMenuItem.Footer: String;
begin
  Result := 'ENTER - Confirm    ESC - Cancel';
end;

procedure TFileMenuItem.Apply;
begin
  if Assigned(OnApply) then OnApply(Self);
  { Safe to build the list here - it is the parent page's items that are on
    the stack, not ours. }
  Rebuild(Path);
  Menu.Show(Self);
end;

procedure TFileMenuItem.Browse(const APath: String);
begin
  FPendingPath := APath;
  FNavigating := True;
end;

procedure TFileMenuItem.AfterInput;
begin
  if not FNavigating then Exit;
  FNavigating := False;
  Rebuild(FPendingPath);
end;

procedure TFileMenuItem.Rebuild(const APath: String);
begin
  Path := APath;
  Warning := '';
  Items.Clear;
  FilteredItems.Clear;
  SelectedIndex := 0;
  if Assigned(OnBrowse) then OnBrowse(Self);
end;

procedure TFileMenuItem.Render(ATop: Integer);
const
  { What fits on one line at this size before it runs off the texture. }
  PathLimit = 58;
var
  Shown: String;
begin
  Shown := Path;
  if Length(Shown) > PathLimit then
    Shown := '...' + Shown.Substring(Length(Shown) - PathLimit);
  DrawTextEx(Font, PChar(Shown), [MenuLeft, ATop], 20, 0, SKYBLUE);

  if not Warning.IsEmpty then
    DrawTextEx(Font, PChar(Warning), [MenuLeft, ATop + 24], 20, 0, RED);

  inherited Render(ATop + 52);
end;

procedure TBindMenuItem.Apply;
begin
  if Assigned(OnApply) then OnApply(Self);
  Menu.Show(Self);
  { The ENTER or the button that opened this page is still held, and this page
    binds whatever it finds down - so nothing counts until it has been let go
    of, and anything typed before the page was asked for is dropped. }
  TInputCapture.Arm;
end;

procedure TBindMenuItem.HandleInput;
var
  Source: TInputSource;
begin
  if IsKeyPressed(KEY_ESCAPE) then
  begin
    Menu.Back;
    Exit;
  end;

  Source := TInputCapture.Poll;
  if Source.Kind = ikNone then Exit;

  { Every button on the page is one to bind, including the ones that work the
    menu - so the press stops here rather than also being acted on. }
  TPadNavigation.Consume;

  { DEL is the one press that stands for no input rather than for itself. }
  if (Source.Kind = ikKey) and (Source.Code = KEY_DELETE) then
    Source := TInputSource.None;

  { OnCapture may free this item along with the page it belongs to, so Back
    is the only thing allowed after it. }
  if Assigned(OnCapture) then OnCapture(Self, Source);
  Menu.Back;
end;

procedure TBindMenuItem.Render(ATop: Integer);
begin
  DrawTextEx(Font, PChar(Prompt), [MenuLeft, ATop], MenuTextSize, 0, ORANGE);
  DrawTextEx(Font, PChar(Value), [MenuLeft, ATop + 48], 32, 0, YELLOW);
end;

function TBindMenuItem.Footer: String;
begin
  Result := 'Press a key or a pad button    DEL - Clear    ESC - Cancel';
end;

constructor TRootMenuItem.Create(AParent: TMenu);
begin
  FItems := TMenuItemList.Create(True);
  FFilteredItems := TMenuItemList.Create(False);
  FMenu := AParent;
end;

function TRootMenuItem.GetMenu: TMenu;
begin
  Result := FMenu;
end;

procedure TMenu.HandleInput;
var
  Page: TMenuItem;
  Notify: TMenuNotify;
begin
  Page := FCurrent;
  Page.HandleInput;

  FCloseRequested := FCloseRequested or IsKeyPressed(KEY_F1)
    or TPadNavigation.Pressed(paMenu);

  { Work the page put off while its own items were running - but not if one of
    them opened another page, or asked to leave. }
  if not FCloseRequested and (FCurrent = Page) then Page.AfterInput;

  { Items ask to leave from inside their own handler, but the owner frees the
    menu in OnClose - so it happens here, once all of their code has returned
    and nothing will touch this object again. }
  if FCloseRequested and Assigned(OnClose) then
  begin
    { The handler frees this menu, and with it the field holding the handler -
      whose captured variables (the owner's Self among them) go with it. The
      local reference keeps it alive until it has returned. }
    Notify := OnClose;
    Notify(Self, FQuitRequested);
  end;
end;

constructor TMenu.Create(AOwner: TComponent);
begin
  Create(AOwner, GetFontDefault);
end;

function TMenu.GetTexture: TTexture2D;
begin
  Result := FTarget.texture;
end;

constructor TMenu.Create(AOwner: TComponent; AFont: TFont);
begin
  inherited Create(AOwner);
  Font := AFont;
  Root := TRootMenuItem.Create(Self);
  Root.Font := AFont;
  FCurrent := Root;


  FTarget := LoadRenderTexture(MenuWidth, MenuHeight);
  SetTextureFilter(FTarget.texture, TEXTURE_FILTER_BILINEAR);
end;

destructor TMenu.Destroy;
begin
  FreeAndNil(Root);
  UnloadRenderTexture(FTarget);
  inherited Destroy;
end;

procedure TMenu.Close;
begin
  FCloseRequested := True;
end;

procedure TMenu.Back;
begin
  if FCurrent = Root then
  begin
    { ESC on the top page is the second ESC of "ESC opens the menu, ESC quits". }
    FQuitRequested := True;
    FCloseRequested := True;
  end
  else
    Show(FCurrent.Parent);
end;

procedure TMenu.Show(AItem: TMenuItem);
begin
  if Assigned(AItem) then FCurrent := AItem;
end;

procedure TMenu.Render;
begin
  BeginTextureMode(FTarget);

  ClearBackground(BLACK);

  DrawRectangle(0, 0, 640, 48, MAROON);

  DrawTextEx(Font, PChar(if FCurrent = Root
    then '>> SPEC <<'
    else '>> ' + FCurrent.Text.ToUpper + ' <<'), [MenuLeft, 6], 36, 0, GOLD);

  FCurrent.Render(64);

  DrawRectangle(0, 480 - 48, 640, 36, DARKBLUE);
  DrawTextEx(Font, PChar(FCurrent.Footer), [MenuLeft, 440], 20, 0, YELLOW);

  DrawTextEx(Font,
    PChar(Copyright),
    [620 - MeasureText(PChar(Copyright), 24), 438],
    24, 0, YELLOW);

  EndTextureMode;
end;

end.
