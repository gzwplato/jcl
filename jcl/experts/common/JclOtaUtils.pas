{**************************************************************************************************}
{                                                                                                  }
{ Project JEDI Code Library (JCL)                                                                  }
{                                                                                                  }
{ The contents of this file are subject to the Mozilla Public License Version 1.1 (the "License"); }
{ you may not use this file except in compliance with the License. You may obtain a copy of the    }
{ License at http://www.mozilla.org/MPL/                                                           }
{                                                                                                  }
{ Software distributed under the License is distributed on an "AS IS" basis, WITHOUT WARRANTY OF   }
{ ANY KIND, either express or implied. See the License for the specific language governing rights  }
{ and limitations under the License.                                                               }
{                                                                                                  }
{ The Original Code is JclOtaUtils.pas.                                                            }
{                                                                                                  }
{ The Initial Developer of the Original Code is documented in the accompanying                     }
{ help file JCL.chm. Portions created by these individuals are Copyright (C) of these individuals. }
{                                                                                                  }
{ Contributors:                                                                                    }
{   Florent Ouchet (outchy)                                                                        }
{                                                                                                  }
{**************************************************************************************************}
{                                                                                                  }
{ Unit owner: Florent Ouchet                                                                       }
{ Last modified: October 19, 2005                                                                  }
{                                                                                                  }
{**************************************************************************************************}

unit JclOtaUtils;

interface

{$I jcl.inc}
{$I windowsonly.inc}

uses
  Windows, Classes, ToolsAPI, ComCtrls, ActnList;

const
  MapFileOptionDetailed  = 3;

type
  TJclOTAUtils = class(TInterfacedObject)
  private
    FBaseRegistryKey: string;
    FExpertRegistryKey: string;
    FEnvVariables: TStringList;
    FRootDir: string;
    FServices: IOTAServices;
    FName: string;
    FNTAServices: INTAServices;
    function GetActiveProject: IOTAProject;
    function GetProjectGroup: IOTAProjectGroup;
    function GetRootDir: string;
    procedure ReadEnvVariables;

    procedure CheckToolBarButton(AToolbar: TToolBar; AAction: TCustomAction);
  public
    constructor Create(AName: string); virtual;
    destructor Destroy; override;
    function FindExecutableName(const MapFileName, OutputDirectory: string;
      var ExecutableFileName: string): Boolean;
    function GetDrcFileName(const Project: IOTAProject): string;
    function GetMapFileName(const Project: IOTAProject): string;
    function GetOutputDirectory(const Project: IOTAProject): string;
    function IsInstalledPackage(const Project: IOTAProject): Boolean;
    function IsPackage(const Project: IOTAProject): Boolean;
    function SubstitutePath(const Path: string): string;

    procedure RegisterAction(Action: TCustomAction);
    procedure UnregisterAction(Action: TCustomAction);
    procedure RegisterCommands; virtual;
    procedure UnregisterCommands; virtual;

    property ActiveProject: IOTAProject read GetActiveProject;
    property BaseRegistryKey: string read FBaseRegistryKey;
    property ExpertRegistryKey: string read FExpertRegistryKey;
    property Name: string read FName;
    property NTAServices: INTAServices read FNTAServices;
    property ProjectGroup: IOTAProjectGroup read GetProjectGroup;
    property RootDir: string read GetRootDir;
    property Services: IOTAServices read FServices;
  end;

  TJclOTAExpert = class(TJclOTAUtils, IOTAWizard)
  protected
    procedure AfterSave;
    procedure BeforeSave;
    procedure Destroyed;
    procedure Modified;
    procedure Execute;
    function GetIDString: string;
    function GetName: string;
    function GetState: TWizardState;
  end;

procedure SaveOptions(const Options: IOTAOptions; const FileName: string);

implementation

uses
  {$IFDEF HAS_UNIT_VARIANTS}
  Variants,
  {$ENDIF HAS_UNIT_VARIANTS}
  SysUtils, ImageHlp,
  JclFileUtils, JclRegistry, JclStrings, JclSysInfo,
  JclOtaConsts, JclOtaResources;

var
  ActionList: TList = nil;
  {$IFNDEF COMPILER6_UP}
  OldFindGlobalComponentProc: TFindGlobalComponent = nil;
  {$ENDIF COMPILER6_UP}

function FindActions(const Name: string): TComponent;
var
  Index: Integer;
  TestAction: TCustomAction;
begin
  Result := nil;
  if Assigned(ActionList) then
    for Index := 0 to ActionList.Count-1 do
    begin
      TestAction := TCustomAction(ActionList.Items[Index]);
      if (CompareText(Name,TestAction.Name) = 0) then
        Result := TestAction;
    end;
  {$IFNDEF COMPILER6_UP}
  if (not Assigned(Result)) and Assigned(OldFindGlobalComponentProc) then
    Result := OldFindGlobalComponentProc(Name)
  {$ENDIF COMPILER6_UP}
end;

//=== { TJclOTAUtils } =======================================================

constructor TJclOTAUtils.Create(AName: string);
begin
  Supports(BorlandIDEServices,IOTAServices,FServices);
  Assert(Assigned(FServices), RsENoIDEServices);

  Supports(FServices,INTAServices,FNTAServices);
  Assert(Assigned(FNTAServices), RsENoNTAServices);

  FName := AName;
  FEnvVariables := TStringList.Create;
  FBaseRegistryKey := StrEnsureSuffix('\', FServices.GetBaseRegistryKey);
  FExpertRegistryKey := FBaseRegistryKey + JediIDESubKey + FName;

  RegisterCommands;
end;

destructor TJclOTAUtils.Destroy;
begin
  UnRegisterCommands;

  FreeAndNil(FEnvVariables);

  FServices := nil;
  FNTAServices := nil;

  inherited Destroy;
end;

function TJclOTAUtils.FindExecutableName(const MapFileName, OutputDirectory: string;
  var ExecutableFileName: string): Boolean;
var
  Se: TSearchRec;
  Res: Integer;
  LatestTime: Integer;
  FileName: TFileName;
  LI: LoadedImage;
begin
  LatestTime := 0;
  ExecutableFileName := '';
  // the latest executable file is very likely our file
  Res := FindFirst(ChangeFileExt(MapFileName, '.*'), faArchive, Se);
  while Res = 0 do
  begin
    FileName := PathAddSeparator(OutputDirectory) + Se.Name;
    if MapAndLoad(PChar(FileName), nil, @LI, False, True) then
    begin
      if (not LI.fDOSImage) and (Se.Time > LatestTime) then
      begin
        ExecutableFileName := FileName;
        LatestTime := Se.Time;
      end;
      UnMapAndLoad(@LI);
    end;
    Res := FindNext(Se);
  end;
  FindClose(Se);
  Result := (ExecutableFileName <> '');
end;

function TJclOTAUtils.GetActiveProject: IOTAProject;
var
  TempProjectGroup: IOTAProjectGroup;
begin
  TempProjectGroup := ProjectGroup;
  if Assigned(TempProjectGroup) then
    Result := TempProjectGroup.ActiveProject
  else
    Result := nil;
end;

function TJclOTAUtils.GetDrcFileName(const Project: IOTAProject): string;
begin
  Result := ChangeFileExt(Project.FileName, DRCExtension);
end;

function TJclOTAUtils.GetMapFileName(const Project: IOTAProject): string;
var
  ProjectFileName, OutputDirectory, LibPrefix, LibSuffix: string;
begin
  ProjectFileName := Project.FileName;
  OutputDirectory := GetOutputDirectory(Project);
  {$IFDEF RTL140_UP}
  LibPrefix := Trim(VarToStr(Project.ProjectOptions.Values[LIBPREFIXOptionName]));
  LibSuffix := Trim(VarToStr(Project.ProjectOptions.Values[LIBSUFFIXOptionName]));
  {$ELSE ~RTL140_UP}
  LibPrefix := '';
  LibSuffix := '';
  {$ENDIF ~RTL140_UP}
  Result := PathAddSeparator(OutputDirectory) + LibPrefix +
    PathExtractFileNameNoExt(ProjectFileName) + LibSuffix + MAPExtension;
end;

function TJclOTAUtils.GetOutputDirectory(const Project: IOTAProject): string;
begin
  if IsPackage(Project) then
  begin
    Result := VarToStr(Project.ProjectOptions.Values[PkgDllDirOptionName]);
    if Result = '' then
      Result := FServices.GetEnvironmentOptions.Values[BPLOutputDirOptionName];
  end
  else
    Result := VarToStr(Project.ProjectOptions.Values[OutputDirOptionName]);
  Result := SubstitutePath(Trim(Result));
  if Result = '' then
    Result := ExtractFilePath(Project.FileName);
end;

function TJclOTAUtils.GetProjectGroup: IOTAProjectGroup;
var
  IModuleServices: IOTAModuleServices;
  I: Integer;
begin
  IModuleServices := BorlandIDEServices as IOTAModuleServices;
  for I := 0 to IModuleServices.ModuleCount - 1 do
    if IModuleServices.Modules[I].QueryInterface(IOTAProjectGroup, Result) = S_OK then
      Exit;
  Result := nil;
end;

function TJclOTAUtils.GetRootDir: string;
begin
  if FRootDir = '' then
  begin
    FRootDir := RegReadStringDef(HKEY_LOCAL_MACHINE, BaseRegistryKey, DelphiRootDirKeyValue, '');
    // (rom) bugfix if using -r switch of D9 by Dan Miser
    if FRootDir = '' then
      FRootDir := RegReadStringDef(HKEY_CURRENT_USER, BaseRegistryKey, DelphiRootDirKeyValue, '');
    Assert(FRootDir <> '');
  end;  
  Result := FRootDir;
end;

function TJclOTAUtils.IsInstalledPackage(const Project: IOTAProject): Boolean;
var
  PackageFileName, ExecutableNameNoExt: string;
  PackageServices: IOTAPackageServices;
  I: Integer;
begin
  Result := IsPackage(Project);
  if Result then
  begin
    Result := False;
    if not Project.ProjectOptions.Values[RuntimeOnlyOptionName] then
    begin
      ExecutableNameNoExt := ChangeFileExt(GetMapFileName(Project), '');
      PackageServices := BorlandIDEServices as IOTAPackageServices;
      for I := 0 to PackageServices.PackageCount - 1 do
      begin
        PackageFileName := ChangeFileExt(PackageServices.PackageNames[I], BPLExtension);
        PackageFileName := GetModulePath(GetModuleHandle(PChar(PackageFileName)));
        if AnsiSameText(ChangeFileExt(PackageFileName, ''), ExecutableNameNoExt) then
        begin
          Result := True;
          Break;
        end;
      end;
    end;
  end;
end;

function TJclOTAUtils.IsPackage(const Project: IOTAProject): Boolean;
begin
  Result := AnsiSameText(ExtractFileExt(Project.FileName), DPKExtension);
end;

procedure TJclOTAUtils.ReadEnvVariables;
{$IFDEF COMPILER6_UP}
var
  EnvNames: TStringList;
  I: Integer;
  EnvVarKeyName: string;
{$ENDIF COMP�LER6_UP}
begin
  FEnvVariables.Clear;

  // read user and system environment variables
  GetEnvironmentVars(FEnvVariables,false);

  // read delphi environment variables
  {$IFDEF COMPILER6_UP}
  EnvNames := TStringList.Create;
  try

    EnvVarKeyName := BaseRegistryKey + EnvironmentVarsKey;
    if RegKeyExists(HKEY_CURRENT_USER, EnvVarKeyName) and
      RegGetValueNames(HKEY_CURRENT_USER, EnvVarKeyName, EnvNames) then
      for I := 0 to EnvNames.Count - 1 do
        FEnvVariables.Values[EnvNames[I]] :=
          RegReadStringDef(HKEY_CURRENT_USER, EnvVarKeyName, EnvNames[I], '');
  finally
    EnvNames.Free;
  end;
  {$ENDIF COMPILER6_UP}

  // add the delphi directory
  FEnvVariables.Values[DelphiEnvironmentVar] := RootDir;
end;

function TJclOTAUtils.SubstitutePath(const Path: string): string;
var
  I: Integer;
  Name: string;
begin
  if FEnvVariables.Count = 0 then
    ReadEnvVariables;
  Result := Path;
  while Pos('$(', Result) > 0 do
    for I := 0 to FEnvVariables.Count - 1 do
    begin
      Name := FEnvVariables.Names[I];
      Result := StringReplace(Result, Format('$(%s)', [Name]),
        FEnvVariables.Values[Name], [rfReplaceAll, rfIgnoreCase]);
    end;
end;

procedure TJclOTAUtils.RegisterAction(Action: TCustomAction);
begin
  if not Assigned(ActionList) then
  begin
    ActionList := TList.Create;
    {$IFDEF COMPILER6_UP}
    RegisterFindGlobalComponentProc(FindActions);
    {$ELSE COMPILER6_UP}
    if not Assigned(OldFindGlobalComponentProc) then
    begin
      OldFindGlobalComponentProc := FindGlobalComponent;
      FindGlobalComponent := FindActions;
    end;
    {$ENDIF COMPILER6_UP}
  end;

  ActionList.Add(Action);
end;

procedure TJclOTAUtils.UnregisterAction(Action: TCustomAction);
begin
  if Assigned(ActionList) then
  begin
    ActionList.Remove(Action);
    if (ActionList.Count = 0) then
    begin
      FreeAndNil(ActionList);
      {$IFDEF COMPILER6_UP}
      UnRegisterFindGlobalComponentProc(FindActions);
      {$ELSE COMPILER6_UP}
      FindGlobalComponent := OldFindGlobalComponentProc;
      {$ENDIF COMPILER6_UP}
    end;
  end;


  // remove action from toolbar to avoid crash when recompile package inside the IDE.
  CheckToolBarButton(FNTAServices.ToolBar[sCustomToolBar], Action);
  CheckToolBarButton(FNTAServices.ToolBar[sStandardToolBar], Action);
  CheckToolBarButton(FNTAServices.ToolBar[sDebugToolBar], Action);
  CheckToolBarButton(FNTAServices.ToolBar[sViewToolBar], Action);
  CheckToolBarButton(FNTAServices.ToolBar[sDesktopToolBar], Action);
  {$IFDEF COMPILER7_UP}
  CheckToolBarButton(FNTAServices.ToolBar[sInternetToolBar], Action);
  CheckToolBarButton(FNTAServices.ToolBar[sCORBAToolBar], Action);
  {$ENDIF COMPILER7_UP}
end;

type
  TAccessToolButton = class(TToolButton);
  
procedure TJclOTAUtils.CheckToolBarButton(AToolbar: TToolBar; AAction: TCustomAction);
var
  Index: Integer;
  AButton: TAccessToolButton;
begin
  if Assigned(AToolBar) then
    for Index := AToolBar.ButtonCount - 1 downto 0 do
    begin
      AButton := TAccessToolButton(AToolBar.Buttons[Index]);
      if AButton.Action = AAction then
      begin
        AButton.SetToolBar(nil);
        AButton.Free;
      end;
    end;
end;

procedure TJclOTAUtils.RegisterCommands;
begin
  // override to add actions and menu items
end;

procedure TJclOTAUtils.UnregisterCommands;
begin
  // override to remove actions and menu items
end;

//=== { TJclOTAExpert } ======================================================

procedure TJclOTAExpert.AfterSave;
begin
end;

procedure TJclOTAExpert.BeforeSave;
begin
end;

procedure TJclOTAExpert.Destroyed;
begin
end;

procedure TJclOTAExpert.Execute;
begin
end;

function TJclOTAExpert.GetIDString: string;
begin
  Result := 'Jedi.' + ClassName;
end;

function TJclOTAExpert.GetName: string;
begin
  Result := ClassName;
end;

function TJclOTAExpert.GetState: TWizardState;
begin
  Result := [];
end;

procedure TJclOTAExpert.Modified;
begin
end;

//=== Helper routines ========================================================

procedure SaveOptions(const Options: IOTAOptions; const FileName: string);
var
  OptArray: TOTAOptionNameArray;
  I: Integer;
begin
  OptArray := Options.GetOptionNames;
  with TStringList.Create do
  try
    for I := Low(OptArray) to High(OptArray) do
      Add(OptArray[I].Name + '=' + VarToStr(Options.Values[OptArray[I].Name]));
    SaveToFile(FileName);
  finally
    Free;
  end;
end;

// History:

// $Log$
// Revision 1.2  2005/10/23 12:53:36  marquardt
// further expert cleanup and integration, use of JclRegistry
//
// Revision 1.1  2005/10/21 12:24:41  marquardt
// experts reorganized with new directory common
//
// Revision 1.3  2005/10/20 22:55:17  outchy
// Experts are now generated by the package generator.
// No WEAKPACKAGEUNIT in design-time packages.
//
// Revision 1.2  2005/10/20 17:19:30  outchy
// Moving function calls out of Asserts
//
// Revision 1.1  2005/10/03 16:15:58  rrossmair
// - moved over from jcl\examples\vcl\debugextension
//
// Revision 1.10  2005/09/17 23:01:46  outchy
// user's settings are now stored in the registry (HKEY_CURRENT_USER)
//
// Revision 1.9  2005/08/07 13:42:38  outchy
// IT3115: Adding system and user environment variables.
//
// Revision 1.8  2005/07/26 17:41:06  outchy
// Icons can now be placed in the IDE's toolbars via the customize dialog. They are restored at the IDE's startup.
//
// Revision 1.7  2005/05/08 15:43:28  outchy
// Compiler conditions modified for C++Builder
//
// Revision 1.6  2005/03/14 05:56:27  rrossmair
// - fixed issue #2752 (TJclOTAUtils.SubstitutePath does not support nested environment variables) as proposed by the reporter.
//

end.