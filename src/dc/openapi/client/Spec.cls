Class dc.openapi.client.Spec Extends %RegisteredObject
{

Parameter XDataName = "OpenAPI";

XData OpenAPI [ MimeType = application/json ]
{
{ "swagger":"2.0" }
}

/// Generate the client classes<br/>
/// Specify your application package in appName argument.<br/>
/// spec is the open api 2.0 specification in JSON Format<br/>
/// It could be a stream, a dynamic object or an URL.<br/>
/// ex: Set sc = ##class(dc.openapi.client.Spec).generateApp("petstore", "https://petstore.swagger.io:443/v2/swagger.json")
ClassMethod generateApp(appName As %String, spec) As %Status
{
    If $Isobject(spec) {
        If spec.%IsA("%Stream.Object") {
            Set spec = {}.%FromJSON(.spec)
        }
    } Else {
        If $ZCONVERT($Extract(spec, 1, 4), "l") = "http" {
            Set spec = ..loadSpecFromUrl(spec)
        } Else {
            Set spec = ..loadSpecFromFile(spec)
        }
    }

    Return ..%CreateClientApplication(appName, spec)
}

ClassMethod loadSpecFromFile(file As %String) As %DynamicObject
{
    Set stream = ##class(%Stream.FileCharacter).%New()
    Set stream.Filename = file
    Set spec = {}.%FromJSON(.stream)
    Return spec
}

ClassMethod loadSpecFromUrl(url As %String) As %DynamicObject
{
    Set request = ##class(%Net.HttpRequest).%New()
    Set request.Server = $Piece($Piece(url,"/",3),":",1)
    Set request.Port = $Piece($Piece(url,"/",3),":",2)
    Set protocol = $Zcvt($Piece(url,":",1),"l")
    Set request.Https = (protocol="https")
    
    If request.Https {
        Set request.SSLConfiguration = "default"
    }

    $$$TOE(sc, request.Send("GET", $Piece(url,"/",4,*)))
    
    If request.HttpResponse.StatusCode '= 200 {
        $$$ThrowStatus($$$ERROR(5001, "Http status code : " _ request.HttpResponse.StatusCode ))
    }

    Return {}.%FromJSON(request.HttpResponse.Data)
}

ClassMethod %CreateClientApplication(applicationName As %String, swagger As %DynamicObject, ByRef features, Output newApplication As %Boolean) As %Status
{
    Set sc = $$$OK
   
    TStart 
    Try {
        
        Set specClass = applicationName _ ".model.spec"

        Set cDef=##class(%Dictionary.ClassDefinition).%OpenId(specClass,4,.sc)
        
        If $Isobject(cDef) {
            Do ..%RemoveXDataBlock(cDef,..#XDataName)
            Set newApplication = $$$NO
        } Else {
            Set cDef=##class(%Dictionary.ClassDefinition).%New(specClass)
            Set newApplication = $$$YES
        }

        ; $$$TOE(sc, ..generateSimpleClient()) ; must be refactor
        ; security to avoid overwrite an existing package on the server ...
        If newApplication && ##class(dc.openapi.client.Generator).packageExists(applicationName)  { 
            Set sc = $$$ERROR(5001, "Overwritting code protection.  This package already exist on the server, please choose an other appName "_applicationName)
            $$$ThrowStatus(sc)
        }

        Set cDef.Super = "%RegisteredObject"
        Set cDef.ProcedureBlock = $$$YES

        Set xData=##class(%Dictionary.XDataDefinition).%New()
        Set xData.Name=..#XDataName
        Set xData.MimeType="application/json"

        Set formatter=##class(%JSON.Formatter).%New()
        
        ; work around for an open problem with the model generation library
        ; https://github.com/grongierisc/objectscript-openapi-definition/issues/4
        Do ..translateSpec(.swagger)
        
        $$$ThrowOnError(formatter.FormatToString(swagger, .swaggerString))
        $$$ThrowOnError(xData.Data.Write(swaggerString))
        $$$ThrowOnError(cDef.XDatas.Insert(xData))
        $$$ThrowOnError(cDef.%Save())
        $$$ThrowOnError($system.OBJ.Compile(specClass,"ck-d"))
        
        Set generator = ##class(dc.openapi.client.Generator).%New(swagger, applicationName, $Get(features("compile"),$$$YES))
        Set sc = generator.generate()

    } Catch (ex) {
        Set sc = ex.AsStatus()
    }

    If $$$ISOK(sc) {
        TCommit 
    } Else {
        TROllback 1
    }
    
    Return sc
}

ClassMethod %RemoveXDataBlock(cDef, blockName)
{
 	Set key = cDef.XDatas.FindObjectId(cDef.Name_"||"_blockName)
 	If (key'="") {
 		Set oid = cDef.XDatas.RemoveAt(key)
	}
}

ClassMethod translateSpec(spec) As %Status
{
    #dim iter As %Iterator.AbstractIterator = spec.paths.%GetIterator()
    #dim serviceLocation As %String
    #dim serviceDefinition As %Library.DynamicObject
    #dim method As %String

    
    While iter.%GetNext(.serviceLocation , .value ) {
        Set methodIter = value.%GetIterator()
        While methodIter.%GetNext(.method , .serviceDefinition ) {
            Set serviceDefinition.operationId = ..translateName(serviceDefinition.operationId)

            If $ISOBJECT(serviceDefinition.responses) {
                Set iterResp = serviceDefinition.responses.%GetIterator()
                While iterResp.%GetNext(.httpStatusCode , .codeObj ) {
                    Set:codeObj.schema."$ref"'="" codeObj.schema."$ref" = ..translateName(codeObj.schema."$ref")
                    Set:codeObj.schema.items."$ref"'="" codeObj.schema.items."$ref" = ..translateName(codeObj.schema.items."$ref")
                }
            }

            If $ISOBJECT(serviceDefinition.parameters) {
                Set iterParams = serviceDefinition.parameters.%GetIterator()
                While iterParams.%GetNext(.paramsKey , .param ) {
                    Set:param.schema."$ref"'="" param.schema."$ref" = ..translateName(param.schema."$ref")
                    Set:param.schema.items."$ref"'="" param.schema.items."$ref" = ..translateName(param.schema.items."$ref")
                }
            }
            
        }
    }

    ;definitions

    
    Set newDef = {}
    
    Set iter = spec.definitions.%GetIterator()

    While iter.%GetNext(.defKey , .def ) {
        
        Set copyDef = {}.%FromJSON(def.%ToJSON())
        Do spec.definitions.%Remove(defKey)

        
        If $ISOBJECT(copyDef.properties) {
            Set iterProp = copyDef.properties.%GetIterator()

            While iterProp.%GetNext(.propKey , .propDef ) {
                Set:propDef."$ref"'="" propDef."$ref" = ..translateName(propDef."$ref")
                Set:propDef.items."$ref"'="" propDef.items."$ref" = ..translateName(propDef.items."$ref")
            }
        }

        Set newDefKey = ..translateName(defKey)
        Do newDef.%Set(..translateName(defKey), copyDef)
    }

    Set spec.definitions = newDef

    Return $$$OK
}

ClassMethod translateName(name As %String) As %IO.StringStream
{
    Return $Translate(name, "_", "")
}

}
