unit DWL.Server;

{$I DWL.inc}

interface

uses
  System.Threading, DWL.Params, DWL.Logging,
  DWL.TCP.HTTP,
  System.Generics.Collections, System.SysUtils,
  DWL.Server.Types;

type
  TDWlServer=class;
  /// <summary>
  ///   The TdwlHTTPHandler class is the base class from which you can derive
  ///   you own handler to process requests
  /// </summary>
  TdwlHTTPHandler = class
    FServer: TDWLServer;
  protected
    /// <summary>
    ///   If the variable FWrapupProc is assigned, it will be called everytime a request has finished
    ///   The handler then can free request specific resources
    ///   When the handler is destroyed, this function will be called with nil parameter
    ///   to indicate that globals resources can be freed
    /// </summary>
    FWrapupProc: TdwlWrapupProc;
    function LogDescription: string; virtual;
  public
    FURI: string;
    property URI: string read FURI;
    property WrapupProc: TdwlWrapupProc read FWrapupProc;
    destructor Destroy; override;
    /// <summary>
    ///   When authorizing clients, the handler that will actual handle the
    ///   request will first be asked to authorize the user and allow this
    ///   user to execute the functions implemented in this handler
    /// </summary>
    function Authorize(const State: PdwlHTTPHandlingState): boolean; virtual;
    /// <summary>
    ///   Override this abstract function and implement the actual process in
    ///   this function
    /// </summary>
    function ProcessRequest(const State: PdwlHTTPHandlingState): boolean; virtual; abstract;
  end;

  TDWLServer = class(TdwlCustomHTTPServer)
  strict private
    FLogLevel: byte;
    FURIAliases: TDictionary<string, string>;
    FOnlyLocalConnections: boolean;
    FExecutionTask: ITask;
    FRootHandlerAccess: TMultiReadExclusiveWriteSynchronizer;
    FRootHandler: TdwlHTTPHandler;
  private
    function GetIsRunning: boolean;
  protected
    function HandleRequest(Request: TdwlHTTPSocket): boolean; override;
    procedure InternalActivate; override;
    procedure InternalDeActivate; override;
  public
    property IsRunning: boolean read GetIsRunning;
    property LogLevel: byte read FLogLevel write FLogLevel;
    property OnlyLocalConnections: boolean read FOnlyLocalConnections write FOnlyLocalConnections;
    constructor Create;
    destructor Destroy; override;
    procedure ProcessRequest(const State: PdwlHTTPHandlingState);
    /// <summary>
    ///   By adding and URL alias, in the case the alias URI is called by a
    ///   client, the traffice is rerouted to the given URI Handler
    /// </summary>
    procedure AddURIAlias(const Alias, Uri: string);
    /// <summary>
    ///   Removes all currentley know URI aliases
    /// </summary>
    procedure ClearURIAliases;
    /// <summary>
    ///   if an Hostname including certificates is added and thus
    ///   the SSL protocol is activated and this function returns true
    /// </summary>
    function IsSecure: boolean;
    /// <summary>
    ///   This will suspend handling, the server will stay active, but the
    ///   handling of the requests will be delayed until ResumeHandling is
    ///   called. Do not suspend handling for a long time.
    /// </summary>
    procedure SuspendHandling;
    /// <summary>
    ///   Resumes handling after it was delayed by Suspendhandling
    /// </summary>
    procedure ResumeHandling;
    /// <summary>
    ///   Get the handler bound to the given URI
    /// </summary>
    function FindHandler(const URI: string): TdwlHTTPHandler;
    /// <summary>
    ///   register a handler bound to a URI. All requests starting with this
    ///   specific URI will be routed through this handler
    /// </summary>
    procedure RegisterHandler(const URI: string; Handler: TdwlHTTPHandler);
    /// <summary>
    ///   Unregister the handler bound to a specific URI
    /// </summary>
    function UnRegisterHandler(const URI: string): boolean;
  end;

procedure AssignServerProcs;

implementation

uses
  System.Classes, DWL.ACME,
  System.Rtti, DWL.Params.Consts, System.StrUtils,
  DWL.MySQL, DWL.Server.Handler.DLL,
  Winapi.Windows, Winapi.ShLwApi, DWL.Server.Consts,
  DWL.HTTP.Consts, DWL.Mail.Queue, IdAssignedNumbers, System.Math, DWL.OpenSSL,
  DWL.TCP.SSL, Winapi.WinInet, DWL.Server.Utils, IdContext, IdCustomHTTPServer,
  DWL.Server.Globals;

type
  TdwlHTTPHandler_PassThrough = class(TdwlHTTPHandler)
  strict private
    FHandlers: TObjectDictionary<string, TdwlHTTPHandler>;
  private
    function FindHandler(const URI: string): TdwlHTTPHandler;
    procedure RegisterHandler(const URI: string; Handler: TdwlHTTPHandler);
    function UnRegisterHandler(const URI: string): boolean;
  protected
    function ProcessRequest(const State: PdwlHTTPHandlingState): boolean; override;
  public
    constructor Create(AServer: TDWLServer);
    destructor Destroy; override;
    function Authorize(const State: PdwlHTTPHandlingState): boolean; override;
  end;

type
  PServerStructure = ^TServerStructure;
  TServerStructure = record
    State_URI: string;
    FinalHandler: TdwlHTTPHandler;
    Tick: UInt64;
    WebSocketsReceiveProc: TdwlHTTPWebSocket_OnData;
    ContentBuffer: pointer;
    ContentLength: cardinal;
    ContentOwned: boolean;
    Request: TdwlHTTPSocket;
  end;

{ TDWLServer }

procedure TDWLServer.AddURIAlias(const Alias, Uri: string);
begin
  if FURIAliases=nil then
    FURIAliases := TDictionary<string, string>.Create;
  FURIAliases.Add(Alias, Uri);
end;

procedure TDWLServer.ClearURIAliases;
begin
  if FURIAliases<>nil then
    FURIAliases.Clear;
end;

constructor TDWLServer.Create;
begin
  inherited Create;
  FLogLevel := httplogLevelWarning;
  FRootHandlerAccess := TMultiReadExclusiveWriteSynchronizer.Create;
  FRootHandler := TdwlHTTPHandler_PassThrough.Create(Self);
end;

destructor TDWLServer.Destroy;
begin
  Active := false;
  FURIAliases.Free;
  FRootHandler.Free;
  FRootHandlerAccess.Free;
  inherited Destroy;
end;

function TDWLServer.FindHandler(const URI: string): TdwlHTTPHandler;
begin
  FRootHandlerAccess.BeginRead;
  try
    Result := TdwlHTTPHandler_PassThrough(FRootHandler).FindHandler(URI);
  finally
    FRootHandlerAccess.EndRead;
  end;
end;

function TDWLServer.GetIsRunning: boolean;
begin
  Result := (FExecutionTask<>nil) and (FExecutionTask.Status=TTaskStatus.Running);
end;

function TDWLServer.HandleRequest(Request: TdwlHTTPSocket): boolean;
  function GetLogLine(State: PdwlHTTPHandlingState): string;
  begin
    var FinalHandler := PServerStructure(State._InternalServerStructure).FinalHandler;
    if FinalHandler<>nil then
      Result := FinalHandler.URI
    else
      Result := '';
    Result := 'Rq '+Request.IP_Remote+':'+Request.Port_Local.ToString+' '+
      dwlhttpCommandToString[State.Command]+' '+Result+PServerStructure(State._InternalServerStructure).State_URI+' '+
      State.StatusCode.ToString+' ('+(GetTickCount64-PServerStructure(State._InternalServerStructure).Tick).ToString+'ms)';
  end;
begin
  Result := false;
  if OnlyLocalConnections then
  begin
    if (Request.IP_Remote<>'127.0.0.1') then
    begin
      Request.StatusCode := HTTP_STATUS_FORBIDDEN;
      Exit;
    end;
  end;
  var State: PdwlHTTPHandlingState := AllocMem(SizeOf(TdwlHTTPHandlingState));
  try
    State._InternalServerStructure := AllocMem(SizeOf(TServerStructure));
    State.Command := Request.Command;
    PServerStructure(State._InternalServerStructure).State_URI := Request.URI;
    PServerStructure(State._InternalServerStructure).Request := Request;
    ProcessRequest(State);
  except
    on E: Exception do
    begin
      TdwlLogger.Log('Exception while handling '+State.URI+': '+E.Message, lsError);
      State.StatusCode := HTTP_STATUS_SERVER_ERROR;
      State.SetContentText('<!DOCTYPE html><html lang=""><head><title>Internal server error</title></head><body>Internal server error</body></html>');
    end;
  end;
  Request.StatusCode := State.StatusCode;
  Request.ResponseDataStream.WriteBuffer(PServerStructure(State._InternalServerStructure).ContentBuffer^, PServerStructure(State._InternalServerStructure).ContentLength);

  if (State.Flags and HTTP_FLAG_NOLOGGING)=0 then
  begin
    if Assigned(PServerStructure(State._InternalServerStructure).WebSocketsReceiveProc) then
      TdwlLogger.Log(GetLogLine(State)+' (websocket closed)', lsTrace)
    else
    begin
      if (State.StatusCode<>HTTP_STATUS_OK) and (LogLevel>=httplogLevelFailedRequests) then
        TdwlLogger.Log(GetLogLine(State), lsNotice)
      else
      begin
        if Loglevel>=httplogLevelAllRequests then
          TdwlLogger.Log(GetLogLine(State), lsTrace)
      end;
    end;
  end
  else
  begin
    if LogLevel>=httplogLevelEverything then
      TdwlLogger.Log(GetLogLine(State), lsTrace);
  end;
  if  PServerStructure(State._InternalServerStructure).ContentOwned then
    FreeMem(PServerStructure(State._InternalServerStructure).ContentBuffer);
  if Assigned(PServerStructure(State._InternalServerStructure).FinalHandler) and
    Assigned(PServerStructure(State._InternalServerStructure).FinalHandler.WrapupProc) then
    PServerStructure(State._InternalServerStructure).FinalHandler.WrapupProc(State);
  PServerStructure(State._InternalServerStructure).State_URI := ''; // dispose string
  Freemem(State._InternalServerStructure);
  FreeMem(State);
  Result := true;
end;

procedure TDWLServer.InternalActivate;
begin
  inherited InternalActivate;
end;

procedure TDWLServer.InternalDeActivate;
begin
  inherited InternalDeActivate;
end;

function TDWLServer.IsSecure: boolean;
begin
  Result := Supports(IoHandler, IdwlSslIoHandler);
end;

procedure TDWLServer.ProcessRequest(const State: PdwlHTTPHandlingState);
begin
  State.StatusCode := HTTP_STATUS_OK;
  var NewURI: string;
  if (FURIAliases<>nil) and FURIAliases.TryGetValue(PServerStructure(State._InternalServerStructure).State_URI, NewURI) then
    PServerStructure(State._InternalServerStructure).State_URI := NewURI;
  // all strings that are put in State as PWiderChar should backed by a Pascal String
  // until State will be freed
  // We arranged this by putting the strings that are referenced in the serverstructure
  State.URI := PWideChar(PServerStructure(State._InternalServerStructure).State_URI);
  State.Flags := 0;
  if (LogLevel>=httplogLevelFailedRequests) then
    PServerStructure(State._InternalServerStructure).Tick := GetTickCount64;
  State.SetHeaderValue(HTTP_HEADER_CACHE_CONTROL, 'no-cache');
  FRootHandlerAccess.BeginRead;
  try
    // RootHandler never needs Authentication Control
    // So no need to check here, just process request
    if (not FRootHandler.ProcessRequest(State)) then
    begin
      State.StatusCode := HTTP_STATUS_NOT_FOUND;
      State.SetContentText('<!DOCTYPE html><html lang=""><head><title>Not Found</title></head><body>Not Found</body></html>');
    end;
  finally
    FRootHandlerAccess.EndRead;
  end;
end;

procedure TDWLServer.RegisterHandler(const URI: string; Handler: TdwlHTTPHandler);
begin
  FRootHandlerAccess.BeginWrite;
  try
    TdwlHTTPHandler_PassThrough(FRootHandler).RegisterHandler(URI, Handler);
  finally
    FRootHandlerAccess.EndWrite;
  end;
end;

procedure TDWLServer.ResumeHandling;
begin
  FRootHandlerAccess.EndWrite;
end;

procedure TDWLServer.SuspendHandling;
begin
  FRootHandlerAccess.BeginWrite;
end;

function TDWLServer.UnRegisterHandler(const URI: string): boolean;
begin
  FRootHandlerAccess.BeginWrite;
  try
    Result := TdwlHTTPHandler_PassThrough(FRootHandler).UnRegisterHandler(URI);
  finally
    FRootHandlerAccess.EndWrite;
  end;
end;

{ TdwlHTTPHandler_PassThrough }

function TdwlHTTPHandler_PassThrough.Authorize(const State: PdwlHTTPHandlingState): boolean;
begin
  // Authorization is always passed through, so for me its ok now!
  Result := true;
end;

constructor TdwlHTTPHandler_PassThrough.Create(AServer: TDWLServer);
begin
  inherited Create;
  FServer := AServer;
  FHandlers := TObjectDictionary<string, TdwlHTTPHandler>.Create([doOwnsValues]);
end;

destructor TdwlHTTPHandler_PassThrough.Destroy;
begin
  FHandlers.Free;
  inherited Destroy;
end;

function TdwlHTTPHandler_PassThrough.FindHandler(const URI: string): TdwlHTTPHandler;
begin
  Result := nil;
  if Copy(URI, 1, 1)<>'/' then
    Exit;
  var S := Copy(URI, 2, MaxInt);
  var P := Pos('/', S);
  var URISegment: string;
  if P>1 then
    URISegment := Copy(S, 1, P-1)
  else
    URISegment := S;
  var Handler: TdwlHTTPHandler;
  if not FHandlers.TryGetValue(URISegment, Handler) then
    Exit;
  if P<1 then // we reached the end: found
    Result := Handler
  else
  begin
    if (Handler is TdwlHTTPHandler_PassThrough) then
      Result := TdwlHTTPHandler_PassThrough(Handler).FindHandler(Copy(S, P, MaxInt));
  end;
end;

function TdwlHTTPHandler_PassThrough.ProcessRequest(const State: PdwlHTTPHandlingState): boolean;
begin
  Result := false;
  var New_URI := PServerStructure(State._InternalServerStructure).State_URI;
  if Copy(New_URI, 1, 1)<>'/' then
    Exit;
  var S := Copy(New_URI, 2, MaxInt);
  var P := Pos('/', S);
  var P2 := Pos('?' , S);
  if (P2>0) and (P2<P) then
    P := P2;
  if P=0 then
    P := MaxInt;
  var Handler: TdwlHTTPHandler;
  if FHandlers.TryGetValue(Copy(S, 1, P-1), Handler) then
  begin
    New_URI := Copy(S, P, MaxInt);
    PServerStructure(State._InternalServerStructure).State_URI := New_URI;
    State.URI := PWideChar(PServerStructure(State._InternalServerStructure).State_URI);
    // Do a security check
    // Before passing request to the found handler
    if Handler.Authorize(State) then
    begin
      PServerStructure(State._InternalServerStructure).FinalHandler := Handler;
      Result := Handler.ProcessRequest(State)
    end
    else
    begin
      // We issue a not found (instead of a denied), because this doesn't reveal unneeded information
      // and if the url is temporary not available, giving a 401 will result in logging out
      // in some clients which we want to prevent
      State.StatusCode := HTTP_STATUS_NOT_FOUND;
      State.SetContentText('<html>Not found.</html>');
      Result := true;
    end;
  end;
end;

procedure TdwlHTTPHandler_PassThrough.RegisterHandler(const URI: string; Handler: TdwlHTTPHandler);
begin
  if Copy(URI, 1, 1)<>'/' then
    raise Exception.Create('URI does not start with a slash');
  var S := Copy(URI, 2, MaxInt);
  var P := Pos('/', S);
  if P>1 then
  begin
    var URISegment := Copy(S, 1, P-1);
    var PassThroughHandler: TdwlHTTPHandler;
    if FHandlers.TryGetValue(URISegment, PassThroughHandler) then
    begin
      if not (PassThroughHandler is TdwlHTTPHandler_PassThrough) then
        raise Exception.Create('URI '+URI+' is already associated with another handler');
    end
    else
    begin
      PassThroughHandler := TdwlHTTPHandler_PassThrough.Create(FServer);
      PassThroughHandler.FURI := FURI+URISegment;
      FHandlers.Add(URISegment, PassThroughHandler);
    end;
    TdwlHTTPHandler_PassThrough(PassThroughHandler).RegisterHandler(Copy(S, P, MaxInt), Handler);
  end
  else
  begin
    FHandlers.Add(S, Handler);
    Handler.FServer := FServer;
    Handler.FURI := FURI+URI;
  end;
end;

function TdwlHTTPHandler_PassThrough.UnRegisterHandler(const URI: string): boolean;
begin
  Result := false;
  if Copy(URI, 1, 1)<>'/' then
    Exit;
  var S := Copy(URI, 2, MaxInt);
  var P := Pos('/', S);
  var URISegment: string;
  if P>1 then
    URISegment := Copy(S, 1, P-1)
  else
    URISegment := S;
  var Handler: TdwlHTTPHandler;
  if not FHandlers.TryGetValue(URISegment, Handler) then
    Exit;
  if P<1 then
  begin  // we reached the end: Do the actual unregister
    FHandlers.Remove(URISegment);
    Result := true;
  end
  else
  begin
    if (Handler is TdwlHTTPHandler_PassThrough) then
      Result := TdwlHTTPHandler_PassThrough(Handler).UnRegisterHandler(Copy(S, P, MaxInt));
  end;
end;

{ TdwlHTTPHandler }

function TdwlHTTPHandler.Authorize(const State: PdwlHTTPHandlingState): boolean;
begin
  Result := false;
end;

destructor TdwlHTTPHandler.Destroy;
begin
  if Assigned(FWrapUpProc) then
  try
    FWrapUpProc(nil);
  except
    On E: Exception do
      TdwlLogger.Log(LogDescription+': exception on wrapup: '+E.Message, lsError)
  end;
  inherited Destroy;
end;

function TdwlHTTPHandler.LogDescription: string;
begin
  Result := Classname;
end;

procedure State_ArrangeContentBuffer(const State: PdwlHTTPHandlingState; var ContentBuffer: pointer; const ContentLength: cardinal); stdcall;
begin
  Assert(PServerStructure(State._InternalServerStructure).ContentBuffer=nil);
  var Owned := ContentBuffer=nil;
  PServerStructure(State._InternalServerStructure).ContentOwned := Owned;
  if Owned then
    GetMem(ContentBuffer, ContentLength);
  PServerStructure(State._InternalServerStructure).ContentLength := ContentLength;
  PServerStructure(State._InternalServerStructure).ContentBuffer := ContentBuffer;
end;

function State_GetRequestParam(const State: PdwlHTTPHandlingState; const Key: PWideChar; const Value: PWideChar; var  ValueCharCnt: integer): integer; stdcall;
begin
  var ValueFound: boolean := false;;
  var FoundStr: string;
  // Keep in mind do not change Value if Result is false
  var Params := PServerStructure(State._InternalServerStructure).Request.RequestParams;
  if Copy(Key, Length(Key)-1, 2)='[]' then // handle as array!
  begin
    var Vals := '';
    for var i := 0 to Params.Count-1 do
    begin
      if SameText(Params.Names[i], Key) then
        Vals := Vals+','+Params.ValueFromIndex[i];
    end;
    ValueFound := Vals<>'';
    if ValueFound then
      FoundStr := Copy(Vals, 2, MaxInt);
  end;
  if not ValueFound then
  begin
    ValueFound := Params.IndexOfName(Key)>=0;
    if ValueFound then
      FoundStr := Params.Values[Key];
  end;
  if not ValueFound then
  begin
    ValueFound := SameText(Key, 'remoteip');
    if ValueFound then
      FoundStr := PServerStructure(State._InternalServerStructure).Request.IP_Remote;
  end;
  if ValueFound then
  begin
    var FoundStrCharCount := Length(FoundStr);
    if ValueCharCnt>=FoundStrCharCount then
    begin
      if FoundStrCharCount>0 then
      begin
        Move(PWideChar(FoundStr)^, Value^, (FoundStrCharCount+1)*2);
      end;
      Result := 1;
    end
    else
      Result := -1;
    ValueCharCnt := FoundStrCharCount;
  end
  else
    Result := 0;
end;

function State_GetHeaderValue(const State: PdwlHTTPHandlingState; const Key: PWideChar; const Value: PWideChar; var  ValueCharCnt: integer): integer; stdcall;
begin
  var FoundStr := PServerStructure(State._InternalServerStructure).Request.RequestHeaders.StrValue(Key);
  if FoundStr='' then
    Exit(0);
  var FoundStrCharCount := Length(FoundStr);
  if ValueCharCnt>=FoundStrCharCount then
  begin
    Result := 1;
    Move(PWideChar(FoundStr)^, Value^, (FoundStrCharCount+1)*2);
  end
  else
    Result := -1;
  ValueCharCnt := FoundStrCharCount;
end;

function State_GetPostDataPtr(State: PdwlHTTPHandlingState; out Data: pointer; out DataSize: Int64): boolean; stdcall;
begin
  var Stream := PServerStructure(State._InternalServerStructure).Request.RequestBodyStream;
  Result := (Stream is TMemoryStream) and (Stream.Size>0);
  if not Result then
    Exit;
  Data := Stream.Memory;
  DataSize := Stream.Size;
end;

procedure State_SetHeaderValue(const State: PdwlHTTPHandlingState; const HeaderKey, Value: PWideChar); stdcall;
begin
  PServerStructure(State._InternalServerStructure).Request.ResponseHeaders.WriteValue(HeaderKey, Value);
end;

procedure AssignServerProcs;
begin
  serverProcs.ArrangeContentBufferProc := State_ArrangeContentBuffer;
  serverProcs.GetRequestParamProc := State_GetRequestParam;
  serverProcs.GetHeaderValueProc := State_GetHeaderValue;
  serverProcs.GetPayloadPtrProc := State_GetPostDataPtr;
  serverProcs.SetHeaderValueProc := State_SetHeaderValue;
//  serverProcs.ActivateWebSocketproc := State_ActivateWebSocket;
end;

end.
