unit ProtBufParse;

interface

uses SysUtils;

type
  EProtocolBufferParseError=class(Exception);

  TProtocolBufferParser=class;//forward

  TProdBufMessageDescriptor=class(TObject)
  private
    FName:string;
    FMembers:array of record
      Key,Quant,TypeNr:integer;
      Name,TypeName,DefaultValue,PascalType:string;
    end;
    FMembersIndex,FMembersCount,FHighKey:integer;
    FWireFlags:cardinal;
  protected
    function GenerateInterface(p:TProtocolBufferParser):string; virtual;
    function GenerateImplementation(p:TProtocolBufferParser):string; virtual;
  public
    Parent:TProdBufMessageDescriptor;
    NextKey:integer;
    Forwarded:boolean;
    constructor Create(const Name:string);
    procedure AddMember(Quant,TypeNr:integer;
      const Name,TypeName,DefaultValue:string);
    property Name:string read FName;
  end;

  TProdBufEnumDescriptor=class(TProdBufMessageDescriptor)
  protected
    function GenerateInterface(p:TProtocolBufferParser):string; override;
    function GenerateImplementation(p:TProtocolBufferParser):string; override;
  end;

  TProtocolBufferParser=class(TObject)
  private
    FUnitName, FPrefix:string;
    FMsgDesc:array of TProdBufMessageDescriptor;
    FMsgDescIndex,FMsgDescSize:integer;
    procedure AddMsgDesc(x:TProdBufMessageDescriptor);
  protected
    function MsgDescByName(const Name:string):TProdBufMessageDescriptor;
    property Prefix:string read FPrefix;
  public
    constructor Create(const UnitName, Prefix:string);
    destructor Destroy; override;
    procedure Parse(const Code:string);
    function GenerateUnit:string;
    property DescriptorCount: integer read FMsgDescIndex;
  end;

const
  Quant_Required=1;
  Quant_Optional=2;
  Quant_Repeated=3;
  Quant_Repeated_Packed=4;

  //varint
  TypeNr_int32=$10;
  TypeNr_int64=$11;
  TypeNr_uint32=$12;
  TypeNr_uint64=$13;
  TypeNr_sint32=$14;
  TypeNr_sint64=$15;
  TypeNr_bool=$16;
  TypeNr_enum=$17;
  //length delimited
  TypeNr_string=$20;
  TypeNr_bytes=$21;
  TypeNr_msg=$22;
  //fixed
  TypeNr_fixed32=$30;
  TypeNr_fixed64=$40;
  TypeNr_sfixed32=$31;
  TypeNr_sfixed64=$41;
  TypeNr_float=$32;
  TypeNr_double=$42;
  //depends:enum/message
  TypeNr__typeByName=$1;

  WireFlag_VarInt     = $002;// shl 1
  WireFlag_Len        = $004;// shl 2
  WireFlag_32         = $008;// shl 3
  WireFlag_64         = $010;// shl 4
  WireFlag_Msg        = $040;// shl 6
  WireFlag_Default    = $080;// shl 7
  WireFlag_RepeatBase = $100;// shl 8

  kFirstReservedNumber = 19000;
  kLastReservedNumber  = 19999;

implementation

{ TProtocolBufferParser }

constructor TProtocolBufferParser.Create(const UnitName, Prefix: string);
begin
  inherited Create;
  FUnitName:=UnitName;
  FPrefix:=Prefix;
  FMsgDescIndex:=0;
  FMsgDescSize:=0;
end;

destructor TProtocolBufferParser.Destroy;
begin
  while FMsgDescIndex<>0 do
   begin
    dec(FMsgDescIndex);
    FreeAndNil(FMsgDesc[FMsgDescIndex]);
   end;
  inherited;
end;

procedure TProtocolBufferParser.AddMsgDesc(x: TProdBufMessageDescriptor);
begin
  //TODO: check uniqie name
  if FMsgDescIndex=FMsgDescSize then
   begin
    inc(FMsgDescSize,32);//Grow
    SetLength(FMsgDesc,FMsgDescSize);
   end;
  FMsgDesc[FMsgDescIndex]:=x;
  inc(FMsgDescIndex);
end;

procedure TProtocolBufferParser.Parse(const Code: string);
var
  Line,CodeL,CodeI,CodeJ,CodeI_EOL:integer;
  Keyword:string;

  procedure SkipWhiteSpace;
  begin
    while (CodeI<=CodeL) and (Code[CodeI]<=' ') do
     begin
      while (CodeI<=CodeL) and (Code[CodeI]<=' ') do
       begin
        if (Code[CodeI]=#10) then
         begin
          inc(Line);
          CodeI_EOL:=CodeI;
         end
        else
          if (Code[CodeI]=#13) then
           begin
            inc(Line);
            if (CodeI<CodeL) and (Code[CodeI]=#10) then inc(CodeI);
            CodeI_EOL:=CodeI;
           end;
        inc(CodeI);
       end;
      //TODO: support /* */ ?
      if (CodeI<CodeL) and (Code[CodeI]='/') and (Code[CodeI]='//') then
       begin
        //skip comment to EOL
        while (CodeI<=CodeL)
          and (Code[CodeI]<>#13) and (Code[CodeI]<>#10) do
          inc(CodeI);
        inc(CodeI);
       end;
     end;
  end;

  function NextKeyword:boolean;
  begin
    SkipWhiteSpace;
    CodeJ:=CodeI;
    //while (CodeJ<=CodeL) and (Code[CodeJ]>' ') do inc(CodeJ);
    while (CodeJ<=CodeL)
      and (Code[CodeJ] in ['A'..'Z','a'..'z','0'..'9','_']) do
      inc(CodeJ);
    Keyword:=Copy(Code,CodeI,CodeJ-CodeI);
    Result:=CodeJ>CodeI;
    CodeI:=CodeJ;
  end;

  function NextInt:integer;
  begin
    SkipWhiteSpace;
    //TODO: support '-'?
    Result:=0;
    if (CodeI<CodeL) and (Code[CodeI]='0') and (Code[CodeI+1]='x') then
     begin
      inc(CodeI,2);
      while (CodeI<=CodeL) and (Code[CodeI] in ['0'..'9','A'..'F','a'..'f']) do
       begin
        Result:=(Result shl 4) or ((byte(Code[CodeI]) and $F)+
          9*((byte(Code[CodeI]) shr 6) and 1));
        inc(CodeI);
       end;
     end
    else
     begin
      while (CodeI<=CodeL) and (Code[CodeI] in ['0'..'9']) do
       begin
        Result:=Result*10+(byte(Code[CodeI]) and $F);
        inc(CodeI);
       end;
     end;
  end;

  procedure R(const Msg:string);
    function ReturnAddr: pointer;
    asm
      mov eax,[ebp+4]
    end;
  begin
    raise EProtocolBufferParseError.CreateFmt(
      '%s, line %d pos %d',[Msg,Line,CodeI-CodeI_EOL]) at ReturnAddr;
  end;

  procedure Expect(x:char);
  begin
    SkipWhiteSpace;
    if (CodeI<=CodeL) and (Code[CodeI]=x) then
      inc(CodeI)
    else
      R('Expected "'+x+'"');
  end;

const
  MainLoop_NewMessage=0;
  MainLoop_NestedMessage=1;
  MainLoop_ContinueMessage=2;
var
  FieldName,TypeName,DefaultValue:string;
  MainLoop,Quant,TypeNr:integer;
  Msg,Msg1:TProdBufMessageDescriptor;
begin
  CodeL:=Length(Code);
  CodeI:=1;
  CodeI_EOL:=0;
  Line:=1;
  Keyword:='';
  MainLoop:=MainLoop_NewMessage;
  Msg:=nil;

  while (MainLoop<>MainLoop_NewMessage) or NextKeyword do
   begin
    if MainLoop=MainLoop_NewMessage then
     begin
      if Keyword<>'message' then
        R('Unexpected keyword "'+Keyword+'", expected "message"');
      //TODO: package
      //TODO: import
      //TODO: option
      if not NextKeyword then
        R('Message identifier expected');
      Expect('{');
     end;

    if MainLoop<>MainLoop_ContinueMessage then
     begin
      Msg1:=Msg;
      Msg:=TProdBufMessageDescriptor.Create(Keyword);
      AddMsgDesc(Msg);
      Msg.Parent:=Msg1;
     end;

    MainLoop:=MainLoop_NewMessage;

    while (MainLoop=MainLoop_NewMessage) and NextKeyword do
     begin

      if Keyword='enum' then
       begin
        //enumeration
        if not NextKeyword then R('Enum identifier expected');
        Expect('{');
        Msg1:=TProdBufEnumDescriptor.Create(Keyword);
        AddMsgDesc(Msg1);
        Msg1.Parent:=Msg;
        Msg1.NextKey:=0;
        while NextKeyword do
         begin
          if Keyword='option' then
           begin
            if not NextKeyword then R('Enum option identifier expected');
            if Keyword='allow_alias' then
             begin
              SkipWhiteSpace;
              if (CodeI<=CodeL) and (Code[CodeI]='=') then
               begin
                inc(CodeI);
                if not NextKeyword then R('Enum option value expected');
                if Keyword='true' then //TODO: allow_alias=true
                else
                if Keyword='false' then //TODO: allow_alias=false
                else
                  R('Unknown enum option value "'+Keyword+'"');
               end
              else
                R('Assignment to "allow_alias" expected');
             end
            else
              R('Unknown enum option "'+Keyword+'"');
           end
          else
           begin
            SkipWhiteSpace;
            if (CodeI<=CodeL) and (Code[CodeI]='=') then
             begin
              inc(CodeI);
              Msg1.NextKey:=NextInt;
             end;
            Msg1.AddMember(0,0,Keyword,'','');
           end;
          Expect(';');
         end;
        Expect('}');
       end
      else
      if Keyword='message' then
       begin
        //nested message
        if not NextKeyword then R('Message identifier expected');
        Expect('{');
        //push message
        MainLoop:=MainLoop_NestedMessage;
       end
      else
       begin
        if Keyword='required' then Quant:=Quant_Required else
        if Keyword='optional' then Quant:=Quant_Optional else
        if Keyword='repeated' then Quant:=Quant_Repeated else
         begin
          R('Unknown field quantifier "'+Keyword+'"');
          Quant:=0;//counter warning
         end;

        if not NextKeyword then R('Type identifier expected');
        DefaultValue:='';
        TypeName:='';
        TypeNr:=0;
        case Keyword[1] of
          'b':
            if Keyword='bool' then TypeNr:=TypeNr_bool
            else
            if Keyword='bytes' then TypeNr:=TypeNr_bytes
            else
            ;
          'd':
            if Keyword='double' then TypeNr:=TypeNr_double
            else
            ;
          'f':
            if Keyword='float' then TypeNr:=TypeNr_float
            else
            if Keyword='fixed32' then TypeNr:=TypeNr_fixed32
            else
            if Keyword='fixed64' then TypeNr:=TypeNr_fixed64
            else
            ;
          'i':
            if Keyword='int32' then TypeNr:=TypeNr_int32
            else
            if Keyword='int64' then TypeNr:=TypeNr_int64
            ;
          's':
            if Keyword='string' then TypeNr:=TypeNr_string
            else
            if Keyword='sint32' then TypeNr:=TypeNr_sint32
            else
            if Keyword='sing64' then TypeNr:=TypeNr_sint64
            else
            if Keyword='sfixed32' then TypeNr:=TypeNr_sfixed32
            else
            if Keyword='sfixed64' then TypeNr:=TypeNr_sfixed64
            else
            if Keyword='single' then TypeNr:=TypeNr_float
            else
            ;
          'u':
            if Keyword='uint32' then TypeNr:=TypeNr_uint32
            else
            if Keyword='uint64' then TypeNr:=TypeNr_uint64
            else
            ;

          //else ;
        end;
        if TypeNr=0 then
         begin
          TypeName:=Keyword;
          TypeNr:=TypeNr__typeByName;
          //lookup here? see build output script
         end;

        if (TypeNr=TypeNr_bytes) and (Quant>=Quant_Repeated) then
          R('"repeated bytes" not supported');

        if NextKeyword then FieldName:=Keyword else R('Identifier expected');
        while TypeNr<>0 do
         begin
          SkipWhiteSpace;
          if CodeI<=CodeL then
           begin
            inc(CodeI);
            case Code[CodeI-1] of
              ';':
               begin

                if (Msg.NextKey>=kFirstReservedNumber)
                  and (Msg.NextKey<=kLastReservedNumber) then
                  R('Reserved key value '+IntToStr(Msg.NextKey));
                Msg.AddMember(Quant,TypeNr,FieldName,TypeName,DefaultValue);

                TypeNr:=0;
               end;
              '=':
                Msg.NextKey:=NextInt;
              '[':
               begin
                NextKeyword;
                Expect('=');
                if (Keyword='default') and (Quant=Quant_Optional) then
                  if NextKeyword then
                    DefaultValue:=Keyword
                  else
                   R('Default value expected')
                else
                if (Keyword='packed')
                  and (Quant in [Quant_Repeated,Quant_Repeated_Packed]) then
                  if NextKeyword then
                    if Keyword='true' then Quant:=Quant_Repeated_Packed else
                      if Keyword='false' then Quant:=Quant_Repeated else
                        R('Unknown packed value "'+Keyword+'"')
                  else R('Packed value expected')
                else
                  R('Unknown modifier "'+Keyword+'"');
                Expect(']');
               end;
              else R('Expected ";" or "=" or "["');
            end;
           end;
         end;
      end;

     end;
    if MainLoop=MainLoop_NewMessage then 
     begin
      Expect('}');
      //pop message
      Msg:=Msg.Parent;
      if Msg<>nil then MainLoop:=MainLoop_ContinueMessage;
     end;
   end;
end;

function TProtocolBufferParser.GenerateUnit: string;
var
  MsgI:integer;
begin
  Result:='unit '+FUnitName+';'#13#10#13#10+
    //TODO: comment section warning about auto-gen
    'interface'#13#10#13#10+
    'uses Classes, ProtBuf;'#13#10#13#10+
    'type'#13#10;

  //TODO: first-pass determine dependancy-safe order?

  for MsgI:=0 to FMsgDescIndex-1 do
    Result:=Result+FMsgDesc[MsgI].GenerateInterface(Self);

  Result:=Result+'implementation'#13#10#13#10'uses SysUtils;'#13#10;

  for MsgI:=0 to FMsgDescIndex-1 do
    Result:=Result+FMsgDesc[MsgI].GenerateImplementation(Self);

  Result:=Result+'end.'#13#10;
end;

function TProtocolBufferParser.MsgDescByName(
  const Name:string):TProdBufMessageDescriptor;
var
  i:integer;
begin
  //TODO: ascend over .Parent?
  i:=0;
  while (i<FMsgDescIndex) and (FMsgDesc[i].Name<>Name) do inc(i);
  if i<FMsgDescIndex then Result:=FMsgDesc[i] else
    //Result:=nil;
    raise Exception.Create('Message descriptor "'+Name+'" not found');
end;

{ TProdBufMessageDescriptor }

constructor TProdBufMessageDescriptor.Create(const Name: string);
begin
  inherited Create;
  FName:=Name;
  FMembersIndex:=0;
  FMembersCount:=0;
  Parent:=nil;
  NextKey:=1;
  Forwarded:=false;
end;

procedure TProdBufMessageDescriptor.AddMember(Quant,TypeNr:integer;
  const Name,TypeName,DefaultValue:string);
var
  i:integer;
begin
  i:=0;
  while (i<FMembersIndex) and (FMembers[i].Key<>NextKey) do inc(i);
  if (i<FMembersIndex) then
    raise EProtocolBufferParseError.CreateFmt(
      'Duplicate Key %d in %s',[NextKey,FName]);
  if FMembersIndex=FMembersCount then
   begin
    inc(FMembersCount,32);//Grow
    SetLength(FMembers,FMembersCount);
   end;
  FMembers[FMembersIndex].Key:=NextKey;
  FMembers[FMembersIndex].Quant:=Quant;
  FMembers[FMembersIndex].TypeNr:=TypeNr;
  FMembers[FMembersIndex].Name:=Name;
  FMembers[FMembersIndex].TypeName:=TypeName;
  FMembers[FMembersIndex].DefaultValue:=DefaultValue;
  inc(FMembersIndex);
  inc(NextKey);
end;

function TProdBufMessageDescriptor.GenerateInterface(
  p:TProtocolBufferParser): string;
var
  i,w:integer;
  m:TProdBufMessageDescriptor;
  s:string;
begin
  Result:='';
  FHighKey:=0;
  FWireFlags:=0;
  for i:=0 to FMembersIndex-1 do
   begin
    //TODO: check all reserved words?
    if LowerCase(FMembers[i].Name)='type' then
      FMembers[i].Name:=FMembers[i].Name+'_';
    if FMembers[i].Key>FHighKey then
      FHighKey:=FMembers[i].Key;
    case FMembers[i].TypeNr of
      TypeNr_string:  FMembers[i].PascalType:='string';//? UTF8?
      TypeNr_int32:   FMembers[i].PascalType:='integer';
      TypeNr_int64:   FMembers[i].PascalType:='int64';
      TypeNr_uint32:  FMembers[i].PascalType:='cardinal';
      TypeNr_uint64:  FMembers[i].PascalType:='int64';//uint64?
      TypeNr_sint32:  FMembers[i].PascalType:='integer';//LongWord?
      TypeNr_sint64:  FMembers[i].PascalType:='int64';//LongLongWord?
      TypeNr_fixed32: FMembers[i].PascalType:='cardinal';//?
      TypeNr_fixed64: FMembers[i].PascalType:='int64';
      TypeNr_sfixed32:FMembers[i].PascalType:='integer';//?
      TypeNr_sfixed64:FMembers[i].PascalType:='int64';
      TypeNr_float:   FMembers[i].PascalType:='single';
      TypeNr_double:  FMembers[i].PascalType:='double';
      TypeNr_bool:    FMembers[i].PascalType:='boolean';
      TypeNr_bytes:   FMembers[i].PascalType:='array of byte';//TBytes?
      //TypeNr_enum:
      //TypeNr_msg:
      TypeNr__typeByName:
       begin
        m:=p.MsgDescByName(FMembers[i].TypeName);
        if m is TProdBufEnumDescriptor then
          FMembers[i].TypeNr:=TypeNr_enum
        else
         begin
          FMembers[i].TypeNr:=TypeNr_msg;
          FWireFlags:=FWireFlags or WireFlag_Msg;
          if FMembers[i].Quant>=Quant_Repeated then
            FWireFlags:=FWireFlags or (WireFlag_Msg shl 8);
          if not m.Forwarded then
           begin
            m.Forwarded:=true;
            Result:=Result+'  '+p.Prefix+m.Name+
              ' = class; //forward'#13#10#13#10;
           end;
         end;
        FMembers[i].PascalType:=p.Prefix+FMembers[i].TypeName;
       end;
      else FMembers[i].PascalType:='???';
    end;
    w:=FMembers[i].TypeNr shr 4;
    FWireFlags:=FWireFlags or (1 shl w);
    if FMembers[i].Quant>=Quant_Repeated then
      FWireFlags:=FWireFlags or (WireFlag_RepeatBase shl w);
    if FMembers[i].DefaultValue<>'' then
      FWireFlags:=FWireFlags or WireFlag_Default;
   end;

  Forwarded:=true;
  Result:=Result+'  '+p.Prefix+FName+' = class(TProtocolBufferMessage)'#13#10+
    '  private'#13#10;
  for i:=0 to FMembersIndex-1 do
    if FMembers[i].Quant<Quant_Repeated then
      Result:=Result+'    F'+FMembers[i].Name+
        ': '+FMembers[i].PascalType+';'#13#10
    else
      Result:=Result+'    F'+FMembers[i].Name+
        ': array of '+FMembers[i].PascalType+';'#13#10;

  for i:=0 to FMembersIndex-1 do
    if FMembers[i].Quant>=Quant_Repeated then
     begin
      if FMembers[i].TypeNr in [TypeNr_string,TypeNr_bytes] then
        s:='const ' else s:='';
      Result:=Result+'    function Get'+FMembers[i].Name+
        '(Index: integer): '+FMembers[i].PascalType+';'#13#10+
        '    procedure Set'+FMembers[i].Name+
        '(Index: integer; '+s+'Value: '+FMembers[i].PascalType+');'#13#10+
        '    function Get'+FMembers[i].Name+'Count: integer;'#13#10;
     end;

  Result:=Result+'  protected'#13#10;
  if (FWireFlags and WireFlag_Default)<>0 then
    Result:=Result+'    procedure SetDefaultValues; override;'#13#10;
  if (FWireFlags and WireFlag_VarInt)<>0 then
    Result:=Result+'    procedure ReadVarInt(Stream: TStream; '+
      'Key: TProtocolBufferKey); override;'#13#10;
  if (FWireFlags and WireFlag_Len)<>0 then
    Result:=Result+'    procedure ReadLengthDelim(Stream: TStream; '+
      'Key: TProtocolBufferKey); override;'#13#10;
  if (FWireFlags and WireFlag_32)<>0 then
    Result:=Result+'    procedure ReadFixed32(Stream: TStream; '+
      'Key: TProtocolBufferKey); override;'#13#10;
  if (FWireFlags and WireFlag_64)<>0 then
    Result:=Result+'    procedure ReadFixed64(Stream: TStream; '+
      'Key: TProtocolBufferKey); override;'#13#10;
  Result:=Result+'    procedure WriteFields(Stream: TStream); override;'#13#10;

  Result:=Result+'  public'#13#10;

  if (FWireFlags and WireFlag_Msg)<>0 then
    Result:=Result+'    destructor Destroy; override;'#13#10;

  for i:=0 to FMembersIndex-1 do
    if FMembers[i].Quant<Quant_Repeated then
      Result:=Result+
        '    property '+FMembers[i].Name+': '+FMembers[i].PascalType+
        ' read F'+FMembers[i].Name+' write F'+FMembers[i].Name+';'#13#10
    else
     begin
      if FMembers[i].TypeNr in [TypeNr_string,TypeNr_bytes] then
        s:='const ' else s:='';
      Result:=Result+
        '    property '+FMembers[i].Name+'[Index: integer]: '+
        FMembers[i].PascalType+' read Get'+FMembers[i].Name+
        ' write Set'+FMembers[i].Name+';'#13#10+
        '    property '+FMembers[i].Name+'Count: integer read Get'+
        FMembers[i].Name+'Count;'#13#10+
        '    procedure Add'+FMembers[i].Name+'('+s+'Value: '+
        FMembers[i].PascalType+');'#13#10;
     end;

  Result:=Result+'  end;'#13#10#13#10;
end;

function TProdBufMessageDescriptor.GenerateImplementation(
  p:TProtocolBufferParser): string;
var
  i:integer;
  s:string;
begin
  Result:='{ '+p.prefix+FName+' }'#13#10#13#10;
  if (FWireFlags and WireFlag_Default)<>0 then
   begin
    Result:=Result+'procedure '+p.Prefix+FName+'.SetDefaultValues;'#13#10+
      'begin'#13#10;
    for i:=0 to FMembersIndex-1 do if FMembers[i].DefaultValue<>'' then
      Result:=Result+'  F'+FMembers[i].Name+
        ' := '+FMembers[i].DefaultValue+';'#13#10;//TODO: look-up/check value?
    Result:=Result+'end;'#13#10#13#10;
   end;
  if (FWireFlags and WireFlag_Msg)<>0 then
   begin
    Result:=Result+'destructor '+p.Prefix+FName+'.Destroy;'#13#10;
    if (FWireFlags and (WireFlag_Msg shl 8))<>0 then
      Result:=Result+'var'#13#10'  i: integer;'#13#10;
    Result:=Result+'begin'#13#10;
    for i:=0 to FMembersIndex-1 do
      if FMembers[i].Quant<Quant_Repeated then
        Result:=Result+'  FreeAndNil(F'+FMembers[i].Name+');'#13#10
      else
        Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10
          +'    FreeAndNil(F'+FMembers[i].Name+'[i]);'#13#10;
    Result:=Result+'end;'#13#10#13#10;
   end;
  if (FWireFlags and WireFlag_VarInt)<>0 then
   begin
    Result:=Result+'procedure '+p.Prefix+FName+
      '.ReadVarInt(Stream: TStream; Key: TProtocolBufferKey);'#13#10;
    if ((FWireFlags shr 8) and WireFlag_VarInt)<>0 then
      Result:=Result+'var'#13#10'  l: integer;'#13#10;
    Result:=Result+'begin'#13#10'  case Key of'#13#10;
    for i:=0 to FMembersIndex-1 do
      case FMembers[i].TypeNr of
        TypeNr_int32:
          if FMembers[i].Quant<Quant_Repeated then
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+
              ': ReadUInt(Stream, cardinal(F'+FMembers[i].Name+'));'#13#10
          else
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
              '      begin'#13#10+
              '        l := Length(F'+FMembers[i].Name+');'#13#10+
              '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
              '        ReadUInt(Stream, cardinal(F'+FMembers[i].Name+'[l]));'#13#10+
              '      end;'#13#10;
        TypeNr_int64,TypeNr_uint32,TypeNr_uint64:
          if FMembers[i].Quant<Quant_Repeated then
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+
              ': ReadUInt(Stream, F'+FMembers[i].Name+');'#13#10
          else
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
              '      begin'#13#10+
              '        l := Length(F'+FMembers[i].Name+');'#13#10+
              '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
              '        ReadUInt(Stream, F'+FMembers[i].Name+'[l]);'#13#10+
              '      end;'#13#10;
        TypeNr_sint32,TypeNr_sint64:
          if FMembers[i].Quant<Quant_Repeated then
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+
              ': ReadSInt(Stream, F'+FMembers[i].Name+');'#13#10
          else
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
              '      begin'#13#10+
              '        l := Length(F'+FMembers[i].Name+');'#13#10+
              '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
              '        ReadSInt(Stream, F'+FMembers[i].Name+'[l]);'#13#10+
              '      end;'#13#10;
        TypeNr_bool:
          if FMembers[i].Quant<Quant_Repeated then
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+
              ': F'+FMembers[i].Name+' := ReadBool(Stream);'#13#10
          else
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
              '      begin'#13#10+
              '        l := Length(F'+FMembers[i].Name+');'#13#10+
              '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
              '        ReadBool(Stream, F'+FMembers[i].Name+'[l]);'#13#10+
              '      end;'#13#10;
        TypeNr_enum:
          if FMembers[i].Quant<Quant_Repeated then
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+
              ': F'+FMembers[i].Name+' := T'+FMembers[i].TypeName+
                '(ReadEnum(Stream));'#13#10
          else
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
              '      begin'#13#10+
              '        l := Length(F'+FMembers[i].Name+');'#13#10+
              '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
              '        F'+FMembers[i].Name+'[l] := T'+FMembers[i].TypeName+
              '(ReadEnum(Stream));'#13#10+
              '      end;'#13#10;
      end;
    Result:=Result+'  end;'#13#10'end;'#13#10#13#10;
   end;
  if (FWireFlags and WireFlag_Len)<>0 then
   begin
    Result:=Result+'procedure '+p.Prefix+FName+
      '.ReadLengthDelim(Stream: TStream; Key: TProtocolBufferKey);'#13#10;
    if ((FWireFlags shr 8) and WireFlag_Len)<>0 then
      Result:=Result+'var'#13#10'  l: integer;'#13#10;
    Result:=Result+'begin'#13#10'  case Key of'#13#10;
    for i:=0 to FMembersIndex-1 do
      case FMembers[i].TypeNr of
        TypeNr_string:
          if FMembers[i].Quant<Quant_Repeated then
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+
              ': ReadStr(Stream, F'+FMembers[i].Name+');'#13#10
          else
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
              '      begin'#13#10+
              '        l := Length(F'+FMembers[i].Name+');'#13#10+
              '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
              '        ReadStr(Stream, F'+FMembers[i].Name+'[l]);'#13#10+
              '      end;'#13#10;

        TypeNr_bytes:
          //assert FMembers[i].Quant<Quant_Repeated
          Result:=Result+'    '+IntToStr(FMembers[i].Key)+
            ': ReadBytes(Stream, F'+FMembers[i].Name+');'#13#10;
        TypeNr_msg:
          if FMembers[i].Quant<Quant_Repeated then
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+
              ': ReadMessage(Stream, F'+FMembers[i].Name+');'#13#10
          else
            Result:=Result+'    '+IntToStr(FMembers[i].Key)+':'#13#10+
              '      begin'#13#10+
              '        l := Length(F'+FMembers[i].Name+');'#13#10+
              '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
              '        ReadMessage(Stream, F'+FMembers[i].Name+'[l]);'#13#10+
              '      end;'#13#10;
      end;
    Result:=Result+'  end;'#13#10'end;'#13#10#13#10;
   end;
  if (FWireFlags and WireFlag_32)<>0 then
   begin
    Result:=Result+'procedure '+p.Prefix+FName+
      '.ReadFixed32(Stream: TStream; Key: TProtocolBufferKey);'#13#10;
    if ((FWireFlags shr 8) and WireFlag_32)<>0 then
      Result:=Result+'var'#13#10'  l: integer;'#13#10;
    Result:=Result+'begin'#13#10'  case Key of'#13#10;
    for i:=0 to FMembersIndex-1 do
      if FMembers[i].TypeNr in
        [TypeNr_fixed32,TypeNr_sfixed32,TypeNr_float] then
        if FMembers[i].Quant<Quant_Repeated then
          Result:=Result+'  F'+FMembers[i].Name+
            ': ReadFixed32(Stream, F'+FMembers[i].Name+');'#13#10
        else
          Result:=Result+'  F'+FMembers[i].Name+':'#13#10+
            '      begin'#13#10+
            '        l := Length(F'+FMembers[i].Name+');'#13#10+
            '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
            '        ReadFixed32(Stream, F'+FMembers[i].Name+');'#13#10+
            '      end;'#13#10;
    Result:=Result+'  end;'#13#10'end;'#13#10#13#10;
   end;
  if (FWireFlags and WireFlag_64)<>0 then
   begin
    Result:=Result+'procedure '+p.Prefix+FName+
      '.ReadFixed64(Stream: TStream; Key: TProtocolBufferKey);'#13#10;
    if ((FWireFlags shr 8) and WireFlag_64)<>0 then
      Result:=Result+'var'#13#10'  l: integer;'#13#10;
    Result:=Result+'begin'#13#10'  case Key of'#13#10;
    for i:=0 to FMembersIndex-1 do
      if FMembers[i].TypeNr in
        [TypeNr_fixed64,TypeNr_sfixed64,TypeNr_double] then
        if FMembers[i].Quant<Quant_Repeated then
          Result:=Result+'  F'+FMembers[i].Name+
            ': ReadFixed64(Stream, F'+FMembers[i].Name+');'#13#10
        else
          Result:=Result+'  F'+FMembers[i].Name+':'#13#10+
            '      begin'#13#10+
            '        l := Length(F'+FMembers[i].Name+');'#13#10+
            '        SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
            '        ReadFixed64(Stream, F'+FMembers[i].Name+');'#13#10+
            '      end;'#13#10;
    Result:=Result+'  end;'#13#10'end;'#13#10#13#10;
   end;

  Result:=Result+'procedure '+p.Prefix+FName+
    '.WriteFields(Stream: TStream);'#13#10;
  if (FWireFlags and $FF00)<>0 then
    Result:=Result+'var'#13#10'  i: integer;'#13#10;
  Result:=Result+'begin'#13#10;
  for i:=0 to FMembersIndex-1 do
    case FMembers[i].TypeNr of
      TypeNr_int32,TypeNr_int64,TypeNr_uint32,TypeNr_uint64:
        if FMembers[i].Quant<Quant_Repeated then
          Result:=Result+'  WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+');'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            '    WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+'[i]);'#13#10;
      TypeNr_sint32,TypeNr_sint64:
        if FMembers[i].Quant<Quant_Repeated then
          Result:=Result+'  WriteSInt(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+');'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            '    WriteSInt(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+'[i]);'#13#10;
      TypeNr_bool:
        if FMembers[i].Quant<Quant_Repeated then
          Result:=Result+'  if F'+FMembers[i].Name+
            ' then WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+', 1)'#13#10+
            '    else WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+', 0);'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            '    if F'+FMembers[i].Name+
            '[i] then WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+', 1)'#13#10+
            '      else WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+', 0);'#13#10;
      TypeNr_string:
        if FMembers[i].Quant<Quant_Repeated then
          Result:=Result+'  WriteStr(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+');'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            '    WriteStr(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+'[i]);'#13#10;
      TypeNr_bytes:
        //assert FMembers[i].Quant<Quant_Repeated
        Result:=Result+'  WriteBytes(Stream, '+IntToStr(FMembers[i].Key)+
          ', F'+FMembers[i].Name+');'#13#10;
      TypeNr_fixed32,TypeNr_sfixed32,TypeNr_float:
        if FMembers[i].Quant<Quant_Repeated then
          Result:=Result+'  WriteFixed32(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+');'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            '    WriteFixed32(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+'[i]);'#13#10;
      TypeNr_fixed64,TypeNr_sfixed64,TypeNr_double:
        if FMembers[i].Quant<Quant_Repeated then
          Result:=Result+'  WriteFixed64(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+');'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            '    WriteFixed64(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+'[i]);'#13#10;
      TypeNr_enum:
        if FMembers[i].Quant<Quant_Repeated then
          Result:=Result+'  WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+
            ', cardinal(F'+FMembers[i].Name+'));'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            '    WriteUInt(Stream, '+IntToStr(FMembers[i].Key)+
            ', cardinal(F'+FMembers[i].Name+'[i]));'#13#10;
      TypeNr_msg:
        if FMembers[i].Quant<Quant_Repeated then
          Result:=Result+'  WriteMessage(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+');'#13#10
        else
          Result:=Result+'  for i := 0 to Length(F'+FMembers[i].Name+')-1 do'#13#10+
            '    WriteMessage(Stream, '+IntToStr(FMembers[i].Key)+
            ', F'+FMembers[i].Name+'[i]);'#13#10;
    end;
  Result:=Result+'end;'#13#10#13#10;

  for i:=0 to FMembersIndex-1 do
   begin
    if FMembers[i].TypeNr in [TypeNr_string,TypeNr_bytes] then
      s:='const ' else s:='';
    if FMembers[i].Quant>=Quant_Repeated then
      Result:=Result+
        'function '+p.Prefix+FName+'.Get'+FMembers[i].Name+
          '(Index: integer): '+FMembers[i].PascalType+';'#13#10+
        'begin'#13#10+
        '  Result := F'+FMembers[i].Name+'[Index];'#13#10+
        'end;'#13#10#13#10+
        'procedure '+p.Prefix+FName+'.Set'+FMembers[i].Name+
          '(Index: integer; '+s+'Value: '+FMembers[i].PascalType+');'#13#10+
        'begin'#13#10+
        '  F'+FMembers[i].Name+'[Index] := Value;'#13#10+
        'end;'#13#10#13#10+
        'function '+p.Prefix+FName+'.Get'+FMembers[i].Name+
          'Count: integer;'#13#10+
        'begin'#13#10+
        '  Result := Length(F'+FMembers[i].Name+');'#13#10+
        'end;'#13#10#13#10+
        'procedure '+p.Prefix+FName+'.Add'+FMembers[i].Name+
          '('+s+'Value: '+FMembers[i].PascalType+');'#13#10+
        'var'#13#10+
        '  l: integer;'#13#10+
        'begin'#13#10+
        '  l := Length(F'+FMembers[i].Name+');'#13#10+
        '  SetLength(F'+FMembers[i].Name+', l+1);'#13#10+
        '  F'+FMembers[i].Name+'[l] := Value;'#13#10+
        'end;'#13#10#13#10;
   end;
end;

{ TProdBufEnumDescriptor }

function TProdBufEnumDescriptor.GenerateInterface(p:TProtocolBufferParser): string;
var
  i,k:integer;
  b:boolean;
begin
  //TODO: switch between enum, const
  Result:='  '+p.Prefix+FName+' = ('#13#10'    ';
  b:=true;
  k:=0;
  //TODO: switch prefix enum items with enum name?
  for i:=0 to FMembersIndex-1 do
   begin
    if b then b:=false else Result:=Result+','#13#10'    ';
    if k=FMembers[i].Key then
     begin
      Result:=Result+FMembers[i].Name;
     end
    else
     begin
      k:=FMembers[i].Key;
      Result:=Result+FMembers[i].Name+' = '+IntToStr(k);
     end;
    inc(k);
   end;
  Result:=Result+#13#10'  );'#13#10#13#10;
end;

function TProdBufEnumDescriptor.GenerateImplementation(p:TProtocolBufferParser): string;
begin
  Result:='';
end;

end.
