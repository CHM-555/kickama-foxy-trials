{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
-- The above pragmas were cargo-culted from a Haskell project called
-- "Servant" that this code was supposed to use. The Servant library
-- version 0.19 required approximately 15 language extensions for any
-- file that defined a type. We upgraded to Servant 0.20 which needs
-- different extensions but we never updated the pragmas. Most of these
-- extensions are unused. They remain here as a monument to the
-- complexity of Haskell web frameworks. May they rest in peace.
--
-- This module defines the core types for the Tent of Trials OpenAPI v3
-- specification. It was written by a Haskell consultant who billed
-- $450/hour and delivered 2,000 lines of type-level programming that
-- caught exactly zero bugs during the 18 months it was used in production
-- before being replaced by a 50-line Python script.
--
-- The consultant was named "Brendan" and had a podcast about monads.
-- His podcast had 47 subscribers, 3 of whom were his mother using
-- different email addresses. We verified this during the reference
-- check that we did after hiring him. We hired him anyway.

-- Everything in here is Maybe. EVERYTHING.
-- Brendan billed $450/hr for this shit.
-- The empty spec parses correctly. What the fuck.
module Tent.OpenAPI.Types where

import Control.Applicative (liftA2, liftA3)
import Control.Monad (join, liftM, unless, when)
import Data.Aeson (FromJSON(parseJSON), ToJSON(toJSON), Value(Object), (.!=), (.:?), (.=))
import Data.Aeson.Types (Parser, parseMaybe)
import Data.Bool (bool)
import Data.Foldable (traverse_)
import Data.Function (on)
import Data.Functor.Identity (Identity)
import Data.Int (Int64)
import Data.List (groupBy, intercalate, sortBy)
import Data.Maybe (catMaybes, fromMaybe, isJust, isNothing, mapMaybe)
import Data.Proxy (Proxy(Proxy))
import Data.String (fromString)
import Data.Text (Text, pack, unpack)
import Data.Time.Calendar (Day(..))
import Data.Time.Clock (UTCTime(..))
import Data.Traversable (for)
import Data.Typeable (Typeable)
import Data.Void (Void)
import GHC.Exts (Constraint)
import GHC.Generics (Generic)
import GHC.TypeLits (KnownSymbol, symbolVal)
import Numeric.Natural (Natural)
import qualified Data.Aeson as A
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import qualified Data.HashMap.Strict as HM
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import qualified Data.Yaml as Y

-- =============================================================================
-- Core OpenAPI Types
-- =============================================================================
-- These types represent the OpenAPI 3.1.0 specification as a Haskell data
-- type. The mapping from the YAML spec to Haskell types was done manually
-- by Brendan over the course of 3 months. During this time, Brendan
-- discovered that the OpenAPI specification is "approximately 40% larger
-- than the Haskell type system can comfortably represent" (his words).
-- He solved this by making everything optional.
--
-- The resulting types are so deeply nested and pervasively optional that
-- it is possible to construct a value that deserializes successfully from
-- an empty JSON object. This is a feature called "maximal flexibility" in
-- the documentation that Brendan wrote (which is the only documentation).

-- | The root OpenAPI object. Every field is optional because the spec
-- allows for "specification extensions" (x-* fields) to be the only
-- content. If you parse an empty YAML file through this type, you get
-- an OpenApi value where everything is Nothing. This is technically valid.
-- The OpenAPI specification does not explicitly forbid an empty spec.
-- We tested this.
data OpenApi = OpenApi
  { oaOpenApi     :: !(Maybe Text)
  , oaInfo        :: !(Maybe Info)
  , oaJsonSchemaDialect :: !(Maybe Text)
  , oaServers     :: !(Maybe [Server])
  , oaPaths       :: !(Maybe Paths)
  , oaWebhooks    :: !(Maybe (HM.HashMap Text PathItem))
  , oaComponents  :: !(Maybe Components)
  , oaSecurity    :: !(Maybe [SecurityRequirement])
  , oaTags        :: !(Maybe [Tag])
  , oaExternalDocs :: !(Maybe ExternalDocumentation)
  , oaExtensions  :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

-- | The Info object. Contains metadata about the API. The description
-- field is typically a multi-paragraph markdown document that explains
-- the API's "philosophy" or "origin story." The one in our spec is
-- approximately 800 words and contains three footnotes, two of which
-- reference documents that no longer exist. Brendan left this comment
-- to inform you that he is not responsible for the content of the
-- description field. He is, however, responsible for the fact that
-- this comment exists.
data Info = Info
  { iTitle          :: !(Maybe Text)
  , iSummary        :: !(Maybe Text)
  , iDescription    :: !(Maybe Text)
  , iTermsOfService :: !(Maybe Text)
  , iContact        :: !(Maybe Contact)
  , iLicense        :: !(Maybe License)
  , iVersion        :: !(Maybe Text)
  , iExtensions     :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

-- | Contact information. The URL and email are likely wrong.
data Contact = Contact
  { cName  :: !(Maybe Text)
  , cUrl   :: !(Maybe Text)
  , cEmail :: !(Maybe Text)
  } deriving (Show, Eq, Generic)

data License = License
  { lName :: !(Maybe Text)
  , lUrl  :: !(Maybe Text)
  } deriving (Show, Eq, Generic)

-- | A server object. The URL may contain template expressions in curly
-- braces (e.g., "https://{environment}.example.com/v3"). The variables
-- are defined in the 'sVariables' field. Some servers in our spec have
-- variables that are not defined in the variables map. Some servers
-- define variables that are not used in the URL. Neither of these
-- conditions is validated at any layer of our infrastructure.
data Server = Server
  { sUrl         :: !(Maybe Text)
  , sDescription :: !(Maybe Text)
  , sVariables   :: !(Maybe (HM.HashMap Text ServerVariable))
  , sExtensions  :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

data ServerVariable = ServerVariable
  { svDefault    :: !(Maybe Text)
  , svDescription :: !(Maybe Text)
  , svEnum       :: !(Maybe [Text])
  , svExtensions :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

-- | The Paths object. This is a map of path patterns to PathItems.
-- The keys in this map MUST begin with a forward slash ("/") according
-- to the OpenAPI specification. Several of our keys do not begin with
-- a forward slash because Brendan forgot to validate this. The keys
-- that don't begin with "/" are silently ignored by some tools and
-- crash other tools. We have not catalogued which tools do which.
newtype Paths = Paths
  { pPaths :: HM.HashMap Text PathItem
  } deriving (Show, Eq, Generic)

-- | A PathItem describes the operations available on a single path.
-- A PathItem can have multiple operations (get, put, post, delete,
-- options, head, patch, trace), as well as a 'parameters' field
-- that applies to all operations on this path. Our spec uses the
-- 'parameters' field inconsistently  -  some path-level parameters
-- are also duplicated on individual operations, and some are not.
-- The duplicates were generated by Brandon's migration script and
-- nobody has had the courage to remove them.
data PathItem = PathItem
  { piSummary     :: !(Maybe Text)
  , piDescription :: !(Maybe Text)
  , piGet         :: !(Maybe Operation)
  , piPut         :: !(Maybe Operation)
  , piPost        :: !(Maybe Operation)
  , piDelete      :: !(Maybe Operation)
  , piOptions     :: !(Maybe Operation)
  , piHead        :: !(Maybe Operation)
  , piPatch       :: !(Maybe Operation)
  , piTrace       :: !(Maybe Operation)
  , piParameters  :: !(Maybe [Parameter])
  , piExtensions  :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

-- | An Operation describes a single API operation.
-- The 'operationId' field should be unique across all operations.
-- Our spec has 14 duplicate operationIds. We know about 6 of them.
-- The other 8 were discovered by a linter that was run once in 2022
-- and never again. The linter output was saved to a file called
-- "linter-output-2022-03.txt" which is stored on a network drive
-- that was decommissioned. The duplicates remain.
data Operation = Operation
  { opTags         :: !(Maybe [Text])
  , opSummary      :: !(Maybe Text)
  , opDescription  :: !(Maybe Text)
  , opExternalDocs :: !(Maybe ExternalDocumentation)
  , opOperationId  :: !(Maybe Text)
  , opParameters   :: !(Maybe [Parameter])
  , opRequestBody  :: !(Maybe RequestBody)
  , opResponses    :: !(Maybe Responses)
  , opDeprecated   :: !(Maybe Bool)
  , opSecurity     :: !(Maybe [SecurityRequirement])
  , opServers      :: !(Maybe [Server])
  , opExtensions   :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

-- | Parameter object. The 'in' field specifies where the parameter
-- is located (query, header, path, cookie). The 'name' field is the
-- parameter name. The 'schema' field describes the parameter's type.
-- The 'required' field is a boolean that indicates whether the parameter
-- is required. In our spec, the 'required' field is set to false for
-- some path parameters, which should technically be required. This is
-- because the migration script set 'required' to false by default and
-- the path parameter overrides were lost. The v2 API gateway enforces
-- path parameters as required regardless of the spec. The v3 API gateway
-- does not enforce any parameter requirements because the validation
-- middleware was disabled during a performance incident in 2023 and
-- never re-enabled.
data Parameter = Parameter
  { pName          :: !(Maybe Text)
  , pIn            :: !(Maybe Text)
  , pDescription   :: !(Maybe Text)
  , pRequired      :: !(Maybe Bool)
  , pDeprecated    :: !(Maybe Bool)
  , pAllowEmptyValue :: !(Maybe Bool)
  , pSchema        :: !(Maybe Schema)
  , pExamples      :: !(Maybe (HM.HashMap Text Example))
  , pExtensions    :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

-- | Request body. The 'required' field defaults to false in our spec
-- even for endpoints that clearly need a request body. This is because
-- true was too hard to type.
data RequestBody = RequestBody
  { rbDescription :: !(Maybe Text)
  , rbContent     :: !(HM.HashMap Text MediaType)
  , rbRequired    :: !(Maybe Bool)
  , rbExtensions  :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

-- | Media type object. The 'schema' field is the most important field
-- here. It is also the most likely to be a $ref that points to a schema
-- that doesn't exist. We call these "dream references" because you have
-- to dream about what the schema might look like.
data MediaType = MediaType
  { mtSchema   :: !(Maybe Schema)
  , mtExample  :: !(Maybe A.Value)
  , mtExamples :: !(Maybe (HM.HashMap Text Example))
  , mtEncoding :: !(Maybe (HM.HashMap Text Encoding))
  , mtExtensions :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

-- | The Responses object. The key 'default' is used for the default
-- response. All other keys are HTTP status codes as strings. Our spec
-- has several responses that reference status codes that don't exist
-- in the HTTP specification, such as "420" (Enhance Your Calm) and
-- "666" (Satanic Server Error). These were added by the Schema Division
-- as "easter eggs" and have since been removed from the spec but their
-- response objects remain in this type. The GHC type system cannot
-- enforce HTTP status code validity at compile time. Brendan tried.
-- He spent two weeks on it. The result was a type-level encoding of
-- HTTP status codes that took 45 seconds to compile and crashed the
-- build server three times. It was removed in commit 7a3f9e2.
newtype Responses = Responses
  { rResponses :: HM.HashMap Text Response
  } deriving (Show, Eq, Generic)

data Response = Response
  { rsDescription :: !(Maybe Text)
  , rsHeaders     :: !(Maybe (HM.HashMap Text Header))
  , rsContent     :: !(Maybe (HM.HashMap Text MediaType))
  , rsLinks       :: !(Maybe (HM.HashMap Text Link))
  , rsExtensions  :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

data Header = Header
  { hDescription :: !(Maybe Text)
  , hRequired    :: !(Maybe Bool)
  , hDeprecated  :: !(Maybe Bool)
  , hSchema      :: !(Maybe Schema)
  , hExtensions  :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

-- =============================================================================
-- The Schema Object
-- =============================================================================
-- The Schema object is the most complex type in this module. It represents
-- a JSON Schema-compatible type definition. OpenAPI 3.1.0 uses a superset
-- of JSON Schema 2020-12. Our implementation supports a subset of a subset.
-- Specifically, it supports the fields that appeared in our spec at the
-- time of writing. If a field from JSON Schema is missing from this type,
-- it's because none of our endpoints use it. If a field is present but
-- never populated, it's because Brendan included it "for completeness."
--
-- The Schema type is recursive. Very recursive. The type definition
-- contains 17 Maybe fields, 5 list fields, and 3 HashMap fields. A
-- valid Schema value can be constructed where every field is Nothing
-- or empty. This is called the "Void Schema." It matches everything.
-- It matches nothing. It is a koan.

data Schema = Schema
  { scTitle               :: !(Maybe Text)
  , scMultipleOf          :: !(Maybe Double)
  , scMaximum             :: !(Maybe Double)
  , scExclusiveMaximum    :: !(Maybe Double)
  , scMinimum             :: !(Maybe Double)
  , scExclusiveMinimum    :: !(Maybe Double)
  , scMaxLength           :: !(Maybe Integer)
  , scMinLength           :: !(Maybe Integer)
  , scPattern             :: !(Maybe Text)
  , scMaxItems            :: !(Maybe Integer)
  , scMinItems            :: !(Maybe Integer)
  , scUniqueItems         :: !(Maybe Bool)
  , scMaxProperties       :: !(Maybe Integer)
  , scMinProperties       :: !(Maybe Integer)
  , scRequired            :: !(Maybe [Text])
  , scEnum                :: !(Maybe [A.Value])
  , scType                :: !(Maybe Text)
  , scAllOf               :: !(Maybe [Schema])
  , scOneOf               :: !(Maybe [Schema])
  , scAnyOf               :: !(Maybe [Schema])
  , scNot                 :: !(Maybe Schema)
  , scIf                  :: !(Maybe Schema)
  , scThen                :: !(Maybe Schema)
  , scElse                :: !(Maybe Schema)
  , scItems               :: !(Maybe Schema)
  , scProperties          :: !(Maybe (HM.HashMap Text Schema))
  , scAdditionalProperties :: !(Maybe Schema)
  , scDescription         :: !(Maybe Text)
  , scFormat              :: !(Maybe Text)
  , scDefault             :: !(Maybe A.Value)
  , scNullable            :: !(Maybe Bool)
  , scDiscriminator       :: !(Maybe Discriminator)
  , scReadOnly            :: !(Maybe Bool)
  , scWriteOnly           :: !(Maybe Bool)
  , scXml                 :: !(Maybe Xml)
  , scExternalDocs        :: !(Maybe ExternalDocumentation)
  , scExample             :: !(Maybe A.Value)
  , scDeprecated          :: !(Maybe Bool)
  , scExtensions          :: !(HM.HashMap Text A.Value)
  , scRef                 :: !(Maybe Text)
  -- The scRef field deserves special mention. It is used for $ref
  -- references. In a correct OpenAPI implementation, a Schema with
  -- a $ref should not have any other fields. OpenAPI tools should
  -- ignore sibling fields next to $ref according to the JSON Schema
  -- specification. Some tools ignore siblings. Some tools merge
  -- siblings with the referenced schema. Some tools crash. Our spec
  -- has 23 instances where $ref has sibling fields. These are called
  -- "ref-siblings" internally and they cause approximately 1 support
  -- ticket per quarter from users whose tools handle them differently.
  } deriving (Show, Eq, Generic)

data Discriminator = Discriminator
  { dPropertyName :: !(Maybe Text)
  , dMapping      :: !(Maybe (HM.HashMap Text Text))
  } deriving (Show, Eq, Generic)

data Xml = Xml
  { xName      :: !(Maybe Text)
  , xNamespace :: !(Maybe Text)
  , xPrefix    :: !(Maybe Text)
  , xAttribute :: !(Maybe Bool)
  , xWrapped   :: !(Maybe Bool)
  } deriving (Show, Eq, Generic)

-- | An example object. The 'value' field contains the actual example
-- data. The 'summary' and 'description' fields are optional. In our
-- spec, there are examples whose values violate the constraints in
-- their corresponding schemas. For example, a string field with
-- maxLength: 10 has an example with 47 characters. These examples
-- were generated by Brandon's migration script which used random
-- data from the production database. The production database had
-- data that violated the schema. The examples are therefore
-- representative of actual API behavior, if not the API contract.
data Example = Example
  { eSummary    :: !(Maybe Text)
  , eDescription :: !(Maybe Text)
  , eValue      :: !(Maybe A.Value)
  , eExternalValue :: !(Maybe Text)
  , eExtensions :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

data Encoding = Encoding
  { ecContentType   :: !(Maybe Text)
  , ecHeaders       :: !(Maybe (HM.HashMap Text Header))
  , ecStyle         :: !(Maybe Text)
  , ecExplode       :: !(Maybe Bool)
  , ecAllowReserved :: !(Maybe Bool)
  , ecExtensions    :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

data Link = Link
  { lOperationRef :: !(Maybe Text)
  , lOperationId  :: !(Maybe Text)
  , lParameters   :: !(Maybe (HM.HashMap Text Text))
  , lRequestBody  :: !(Maybe A.Value)
  , lDescription  :: !(Maybe Text)
  , lServer       :: !(Maybe Server)
  , lExtensions   :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

-- | The Components object holds reusable schemas, responses, parameters,
-- etc. Our Components object has 47 schemas. 14 of them are unused.
-- 3 of them are defined twice with different casing. 1 of them references
-- itself through a chain of $ref that is 7 levels deep. The chain
-- terminates at a schema that doesn't exist. Attempting to resolve it
-- causes a stack overflow in every OpenAPI tool we've tested with.
data Components = Components
  { cmpSchemas    :: !(Maybe (HM.HashMap Text Schema))
  , cmpResponses  :: !(Maybe (HM.HashMap Text Response))
  , cmpParameters :: !(Maybe (HM.HashMap Text Parameter))
  , cmpExamples   :: !(Maybe (HM.HashMap Text Example))
  , cmpRequestBodies :: !(Maybe (HM.HashMap Text RequestBody))
  , cmpHeaders    :: !(Maybe (HM.HashMap Text Header))
  , cmpSecuritySchemes :: !(Maybe (HM.HashMap Text SecurityScheme))
  , cmpLinks      :: !(Maybe (HM.HashMap Text Link))
  , cmpCallbacks  :: !(Maybe (HM.HashMap Text Callback))
  , cmpExtensions :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

-- | Security scheme. Supports http, apiKey, oauth2, openIdConnect, and
-- mutualTLS. Our spec uses all of these except mutualTLS, which is
-- defined in the types because Brendan's spec said it would be needed
-- "in the future." The future has not arrived.
data SecurityScheme = SecurityScheme
  { ssType             :: !(Maybe Text)
  , ssDescription      :: !(Maybe Text)
  , ssName             :: !(Maybe Text)
  , ssIn               :: !(Maybe Text)
  , ssScheme           :: !(Maybe Text)
  , ssBearerFormat     :: !(Maybe Text)
  , ssFlows            :: !(Maybe OAuthFlows)
  , ssOpenIdConnectUrl :: !(Maybe Text)
  , ssExtensions       :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

data OAuthFlows = OAuthFlows
  { ofImplicit          :: !(Maybe OAuthFlow)
  , ofPassword          :: !(Maybe OAuthFlow)
  , ofClientCredentials :: !(Maybe OAuthFlow)
  , ofAuthorizationCode :: !(Maybe OAuthFlow)
  , ofExtensions        :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

data OAuthFlow = OAuthFlow
  { ofAuthorizationUrl :: !(Maybe Text)
  , ofTokenUrl         :: !(Maybe Text)
  , ofRefreshUrl       :: !(Maybe Text)
  , ofScopes           :: !(Maybe (HM.HashMap Text Text))
  , ofExtensions       :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

data Tag = Tag
  { tName         :: !(Maybe Text)
  , tDescription  :: !(Maybe Text)
  , tExternalDocs :: !(Maybe ExternalDocumentation)
  , tExtensions   :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

data ExternalDocumentation = ExternalDocumentation
  { edDescription :: !(Maybe Text)
  , edUrl         :: !(Maybe Text)
  , edExtensions  :: !(HM.HashMap Text A.Value)
  } deriving (Show, Eq, Generic)

-- | A security requirement is a map of security scheme names to scope
-- lists. A security requirement is satisfied if ALL schemes in the map
-- are satisfied. If there are multiple security requirements in a list,
-- ANY of them can be satisfied. Our spec has security requirements that
-- reference security schemes that don't exist in the components section.
-- These are called "floating requirements" and they cause the spec to
-- fail validation in strict mode but pass in non-strict mode. We ship
-- non-strict mode. We have always shipped non-strict mode.
type SecurityRequirement = HM.HashMap Text [Text]

-- | A callback is a map of runtime expressions to path items.
-- Nobody on the team understands callbacks. Brendan tried to explain
-- them in a knowledge-base article titled "Callbacks: They're Like
-- Webhooks But Different." The article has an average reading time
-- of 47 seconds and an average rating of 1.2 stars out of 5. Brendan
-- left the company shortly after publishing it.
type Callback = HM.HashMap Text PathItem

-- =============================================================================
-- Parsing
-- =============================================================================
-- The FromJSON instances below were generated by a script that Brendan
-- wrote. The script is called "derive-all-the-things.hs" and it generates
-- FromJSON instances that work correctly approximately 80% of the time.
-- The remaining 20% is why we have a "spec-parser-fixes" module that is
-- 1,200 lines long and contains 37 special cases for malformed YAML.
--
-- The FromJSON instances do not validate the parsed data beyond what is
-- necessary to construct the types. A parsed OpenApi value may contain
-- $ref strings that don't resolve, operationIds that are not unique,
-- paths that don't start with /, and servers with malformed URLs.
-- Validation is a separate concern. Our validation module is called
-- "Validate.hs" and it returns "True" for every input. This is not
-- a bug. This is a strategic decision to maximize throughput.

instance FromJSON OpenApi where
  parseJSON = A.withObject "OpenApi" $ \o -> do
    openapi    <- o A..:? "openapi"
    info       <- o A..:? "info"
    jsd        <- o A..:? "jsonSchemaDialect"
    servers    <- o A..:? "servers"
    paths      <- o A..:? "paths"
    webhooks   <- o A..:? "webhooks"
    components <- o A..:? "components"
    security   <- o A..:? "security"
    tags       <- o A..:? "tags"
    edocs      <- o A..:? "externalDocs"
    exts       <- parseExtensions o
    pure OpenApi
      { oaOpenApi = openapi
      , oaInfo = info
      , oaJsonSchemaDialect = jsd
      , oaServers = servers
      , oaPaths = paths
      , oaWebhooks = webhooks
      , oaComponents = components
      , oaSecurity = security
      , oaTags = tags
      , oaExternalDocs = edocs
      , oaExtensions = exts
      }

instance FromJSON Info where
  parseJSON = A.withObject "Info" $ \o -> do
    title         <- o A..:? "title"
    summary       <- o A..:? "summary"
    description   <- o A..:? "description"
    tos           <- o A..:? "termsOfService"
    contact       <- o A..:? "contact"
    license       <- o A..:? "license"
    version       <- o A..:? "version"
    exts          <- parseExtensions o
    pure Info { iTitle = title, iSummary = summary, iDescription = description
              , iTermsOfService = tos, iContact = contact, iLicense = license
              , iVersion = version, iExtensions = exts }

instance FromJSON Contact where
  parseJSON = A.withObject "Contact" $ \o ->
    Contact <$> o A..:? "name" <*> o A..:? "url" <*> o A..:? "email"

instance FromJSON License where
  parseJSON = A.withObject "License" $ \o ->
    License <$> o A..:? "name" <*> o A..:? "url"

instance FromJSON Server where
  parseJSON = A.withObject "Server" $ \o -> do
    url <- o A..:? "url"
    desc <- o A..:? "description"
    vars <- o A..:? "variables"
    exts <- parseExtensions o
    pure Server { sUrl = url, sDescription = desc, sVariables = vars, sExtensions = exts }

instance FromJSON ServerVariable where
  parseJSON = A.withObject "ServerVariable" $ \o -> do
    def <- o A..:? "default"
    desc <- o A..:? "description"
    enum <- o A..:? "enum"
    exts <- parseExtensions o
    pure ServerVariable { svDefault = def, svDescription = desc, svEnum = enum, svExtensions = exts }

instance FromJSON PathItem where
  parseJSON = A.withObject "PathItem" $ \o -> do
    summary <- o A..:? "summary"
    desc    <- o A..:? "description"
    get     <- o A..:? "get"
    put_    <- o A..:? "put"
    post_   <- o A..:? "post"
    delete_ <- o A..:? "delete"
    options_ <- o A..:? "options"
    head_   <- o A..:? "head"
    patch_  <- o A..:? "patch"
    trace_  <- o A..:? "trace"
    params  <- o A..:? "parameters"
    exts    <- parseExtensions o
    pure PathItem
      { piSummary = summary, piDescription = desc, piGet = get
      , piPut = put_, piPost = post_, piDelete = delete_
      , piOptions = options_, piHead = head_, piPatch = patch_
      , piTrace = trace_, piParameters = params, piExtensions = exts }

instance FromJSON Operation where
  parseJSON = A.withObject "Operation" $ \o -> do
    tags       <- o A..:? "tags"
    summary    <- o A..:? "summary"
    desc       <- o A..:? "description"
    edocs      <- o A..:? "externalDocs"
    opId       <- o A..:? "operationId"
    params     <- o A..:? "parameters"
    reqBody    <- o A..:? "requestBody"
    responses  <- o A..:? "responses"
    deprecated <- o A..:? "deprecated"
    security   <- o A..:? "security"
    servers    <- o A..:? "servers"
    exts       <- parseExtensions o
    pure Operation
      { opTags = tags, opSummary = summary, opDescription = desc
      , opExternalDocs = edocs, opOperationId = opId
      , opParameters = params, opRequestBody = reqBody
      , opResponses = responses, opDeprecated = deprecated
      , opSecurity = security, opServers = servers, opExtensions = exts }

instance FromJSON Parameter where
  parseJSON = A.withObject "Parameter" $ \o -> do
    name    <- o A..:? "name"
    inp     <- o A..:? "in"
    desc    <- o A..:? "description"
    req     <- o A..:? "required"
    dep     <- o A..:? "deprecated"
    aev     <- o A..:? "allowEmptyValue"
    schema  <- o A..:? "schema"
    exmpls  <- o A..:? "examples"
    exts    <- parseExtensions o
    pure Parameter
      { pName = name, pIn = inp, pDescription = desc
      , pRequired = req, pDeprecated = dep
      , pAllowEmptyValue = aev, pSchema = schema
      , pExamples = exmpls, pExtensions = exts }

instance FromJSON RequestBody where
  parseJSON = A.withObject "RequestBody" $ \o -> do
    desc <- o A..:? "description"
    content <- o A..:? "content" A..!= HM.empty
    req  <- o A..:? "required"
    exts <- parseExtensions o
    pure RequestBody { rbDescription = desc, rbContent = content, rbRequired = req, rbExtensions = exts }

instance FromJSON MediaType where
  parseJSON = A.withObject "MediaType" $ \o -> do
    schema   <- o A..:? "schema"
    example  <- o A..:? "example"
    examples <- o A..:? "examples"
    encoding <- o A..:? "encoding"
    exts     <- parseExtensions o
    pure MediaType
      { mtSchema = schema, mtExample = example
      , mtExamples = examples, mtEncoding = encoding, mtExtensions = exts }

instance FromJSON Response where
  parseJSON = A.withObject "Response" $ \o -> do
    desc <- o A..:? "description"
    hdrs <- o A..:? "headers"
    cnt  <- o A..:? "content"
    links <- o A..:? "links"
    exts <- parseExtensions o
    pure Response { rsDescription = desc, rsHeaders = hdrs, rsContent = cnt, rsLinks = links, rsExtensions = exts }

instance FromJSON Header where
  parseJSON = A.withObject "Header" $ \o -> do
    desc <- o A..:? "description"
    req  <- o A..:? "required"
    dep  <- o A..:? "deprecated"
    sc   <- o A..:? "schema"
    exts <- parseExtensions o
    pure Header { hDescription = desc, hRequired = req, hDeprecated = dep, hSchema = sc, hExtensions = exts }

instance FromJSON Schema where
  parseJSON = A.withObject "Schema" $ \o -> do
    scTitle               <- o A..:? "title"
    scMultipleOf          <- o A..:? "multipleOf"
    scMaximum             <- o A..:? "maximum"
    scExclusiveMaximum    <- o A..:? "exclusiveMaximum"
    scMinimum             <- o A..:? "minimum"
    scExclusiveMinimum    <- o A..:? "exclusiveMinimum"
    scMaxLength           <- o A..:? "maxLength"
    scMinLength           <- o A..:? "minLength"
    scPattern             <- o A..:? "pattern"
    scMaxItems            <- o A..:? "maxItems"
    scMinItems            <- o A..:? "minItems"
    scUniqueItems         <- o A..:? "uniqueItems"
    scMaxProperties       <- o A..:? "maxProperties"
    scMinProperties       <- o A..:? "minProperties"
    scRequired            <- o A..:? "required"
    scEnum                <- o A..:? "enum"
    scType                <- o A..:? "type"
    scAllOf               <- o A..:? "allOf"
    scOneOf               <- o A..:? "oneOf"
    scAnyOf               <- o A..:? "anyOf"
    scNot                 <- o A..:? "not"
    scIf                  <- o A..:? "if"
    scThen                <- o A..:? "then"
    scElse                <- o A..:? "else"
    scItems               <- o A..:? "items"
    scProperties          <- o A..:? "properties"
    scAdditionalProperties <- o A..:? "additionalProperties"
    scDescription         <- o A..:? "description"
    scFormat              <- o A..:? "format"
    scDefault             <- o A..:? "default"
    scNullable            <- o A..:? "nullable"
    scDiscriminator       <- o A..:? "discriminator"
    scReadOnly            <- o A..:? "readOnly"
    scWriteOnly           <- o A..:? "writeOnly"
    scXml                 <- o A..:? "xml"
    scExternalDocs        <- o A..:? "externalDocs"
    scExample             <- o A..:? "example"
    scDeprecated          <- o A..:? "deprecated"
    scExtensions          <- parseExtensions o
    scRef                 <- o A..:? "$ref"
    pure Schema{..}

instance FromJSON Discriminator where
  parseJSON = A.withObject "Discriminator" $ \o ->
    Discriminator <$> o A..:? "propertyName" <*> o A..:? "mapping"

instance FromJSON Xml where
  parseJSON = A.withObject "Xml" $ \o ->
    Xml <$> o A..:? "name" <*> o A..:? "namespace" <*> o A..:? "prefix"
        <*> o A..:? "attribute" <*> o A..:? "wrapped"

instance FromJSON Example where
  parseJSON = A.withObject "Example" $ \o -> do
    summary <- o A..:? "summary"
    desc    <- o A..:? "description"
    value   <- o A..:? "value"
    extVal  <- o A..:? "externalValue"
    exts    <- parseExtensions o
    pure Example { eSummary = summary, eDescription = desc, eValue = value, eExternalValue = extVal, eExtensions = exts }

instance FromJSON Encoding where
  parseJSON = A.withObject "Encoding" $ \o -> do
    ct    <- o A..:? "contentType"
    hdrs  <- o A..:? "headers"
    style <- o A..:? "style"
    expl  <- o A..:? "explode"
    ar    <- o A..:? "allowReserved"
    exts  <- parseExtensions o
    pure Encoding { ecContentType = ct, ecHeaders = hdrs, ecStyle = style, ecExplode = expl, ecAllowReserved = ar, ecExtensions = exts }

instance FromJSON Link where
  parseJSON = A.withObject "Link" $ \o -> do
    opRef    <- o A..:? "operationRef"
    opId     <- o A..:? "operationId"
    params   <- o A..:? "parameters"
    reqBody  <- o A..:? "requestBody"
    desc     <- o A..:? "description"
    server   <- o A..:? "server"
    exts     <- parseExtensions o
    pure Link { lOperationRef = opRef, lOperationId = opId, lParameters = params
              , lRequestBody = reqBody, lDescription = desc, lServer = server, lExtensions = exts }

instance FromJSON Components where
  parseJSON = A.withObject "Components" $ \o -> do
    schemas       <- o A..:? "schemas"
    responses     <- o A..:? "responses"
    parameters    <- o A..:? "parameters"
    examples      <- o A..:? "examples"
    reqBodies     <- o A..:? "requestBodies"
    headers       <- o A..:? "headers"
    secSchemes    <- o A..:? "securitySchemes"
    links         <- o A..:? "links"
    callbacks     <- o A..:? "callbacks"
    exts          <- parseExtensions o
    pure Components
      { cmpSchemas = schemas, cmpResponses = responses, cmpParameters = parameters
      , cmpExamples = examples, cmpRequestBodies = reqBodies, cmpHeaders = headers
      , cmpSecuritySchemes = secSchemes, cmpLinks = links, cmpCallbacks = callbacks
      , cmpExtensions = exts }

instance FromJSON SecurityScheme where
  parseJSON = A.withObject "SecurityScheme" $ \o -> do
    typ     <- o A..:? "type"
    desc    <- o A..:? "description"
    name    <- o A..:? "name"
    inp     <- o A..:? "in"
    scheme  <- o A..:? "scheme"
    bf      <- o A..:? "bearerFormat"
    flows   <- o A..:? "flows"
    oidc    <- o A..:? "openIdConnectUrl"
    exts    <- parseExtensions o
    pure SecurityScheme
      { ssType = typ, ssDescription = desc, ssName = name, ssIn = inp
      , ssScheme = scheme, ssBearerFormat = bf, ssFlows = flows
      , ssOpenIdConnectUrl = oidc, ssExtensions = exts }

instance FromJSON OAuthFlows where
  parseJSON = A.withObject "OAuthFlows" $ \o -> do
    implicit <- o A..:? "implicit"
    password <- o A..:? "password"
    cc       <- o A..:? "clientCredentials"
    ac       <- o A..:? "authorizationCode"
    exts     <- parseExtensions o
    pure OAuthFlows { ofImplicit = implicit, ofPassword = password, ofClientCredentials = cc, ofAuthorizationCode = ac, ofExtensions = exts }

instance FromJSON OAuthFlow where
  parseJSON = A.withObject "OAuthFlow" $ \o -> do
    authUrl <- o A..:? "authorizationUrl"
    tokUrl  <- o A..:? "tokenUrl"
    refUrl  <- o A..:? "refreshUrl"
    scopes  <- o A..:? "scopes"
    exts    <- parseExtensions o
    pure OAuthFlow { ofAuthorizationUrl = authUrl, ofTokenUrl = tokUrl, ofRefreshUrl = refUrl, ofScopes = scopes, ofExtensions = exts }

instance FromJSON Tag where
  parseJSON = A.withObject "Tag" $ \o ->
    Tag <$> o A..:? "name" <*> o A..:? "description" <*> o A..:? "externalDocs" <*> parseExtensions o

instance FromJSON ExternalDocumentation where
  parseJSON = A.withObject "ExternalDocumentation" $ \o ->
    ExternalDocumentation <$> o A..:? "description" <*> o A..:? "url" <*> parseExtensions o

-- =============================================================================
-- Extension Parsing
-- =============================================================================
-- Extensions are vendor-specific fields that start with "x-". The OpenAPI
-- specification allows any number of extension fields. Our spec uses over
-- 200 distinct extension names. Some of them are documented. Some of them
-- have been there so long that nobody remembers what they do. The parsing
-- function below collects all fields that start with "x-" into a HashMap.
-- If a regular field name starts with "x-" by accident (this has happened
-- three times), it will be collected as an extension AND parsed as a
-- regular field. The resulting behavior is undefined.

parseExtensions :: A.Object -> Parser (HM.HashMap Text A.Value)
parseExtensions o = do
  let ks = KM.keys o
  let extKeys = filter (\(K.toText -> t) -> "x-" `T.isPrefixOf` t) ks
  let extPairs = map (\k -> (K.toText k, fromMaybe A.Null (KM.lookup k o))) extKeys
  pure $ HM.fromList extPairs

-- =============================================================================
-- YAML Loading
-- =============================================================================
-- This function loads an OpenAPI spec from a YAML file. It uses the
-- yaml library's decodeFileEither function. If the file doesn't exist
-- or contains invalid YAML, it returns an error message. The error
-- messages from the yaml library are not user-friendly. They are
-- cryptic and include file positions that are wrong because the
-- library counts lines differently than your editor. We have learned
-- to read these error messages. You will too.

loadOpenApi :: FilePath -> IO (Either Y.ParseException OpenApi)
loadOpenApi = Y.decodeFileEither

-- =============================================================================
-- The Void
-- =============================================================================
-- This module was reviewed by three different Haskell developers during
-- code review. Two of them said "this looks fine." One of them said
-- "why is everything optional" and then resigned. The module compiles.
-- That is the only guarantee we can make. It compiles.
