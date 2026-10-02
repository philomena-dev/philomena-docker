-- Signs requests to object storage (AWS Signature Version 4) and tidies up
-- the responses. Used by cdn/storage.conf.
--
-- Settings come from the environment: S3_SCHEME, S3_HOST, S3_PORT, S3_BUCKET,
-- AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, and optionally S3_REGION.

local digest = require('resty.openssl.digest')
local hmac = require('resty.openssl.hmac')
local str = require('resty.string')

local _M = {}

local EMPTY_BODY_SHA256 = 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
local SIGNED_HEADERS = 'host;x-amz-content-sha256;x-amz-date'

-- Request headers that are answered from the cache by nginx itself. They are
-- never passed on to the storage service.
local KEPT_HEADERS = {
  ['range'] = true,
  ['if-range'] = true,
  ['if-match'] = true,
  ['if-none-match'] = true,
  ['if-modified-since'] = true,
  ['if-unmodified-since'] = true,
}

-- Files in the bucket can carry any content type, including none at all.
-- What visitors receive is decided by the file extension alone, so that a
-- file can never be served as something a browser would execute.
local CONTENT_TYPES = {
  png = 'image/png',
  jpg = 'image/jpeg',
  jpeg = 'image/jpeg',
  gif = 'image/gif',
  svg = 'image/svg+xml',
  webp = 'image/webp',
  mp4 = 'video/mp4',
  webm = 'video/webm',
}

local function required_env(name)
  local value = os.getenv(name)

  if value == nil or value == '' then
    error(name .. ' is not set')
  end

  return value
end

local config

local function get_config()
  if config then
    return config
  end

  local scheme = required_env('S3_SCHEME')
  local host = required_env('S3_HOST')
  local port = required_env('S3_PORT')
  local region = os.getenv('S3_REGION')
  local default_port = scheme == 'https' and '443' or '80'

  config = {
    upstream = scheme .. '://' .. host .. ':' .. port,
    -- The value of the Host header, which is part of the signature.
    host = port == default_port and host or (host .. ':' .. port),
    name = host,
    bucket = required_env('S3_BUCKET'),
    region = (region ~= nil and region ~= '') and region or 'auto',
    access_key = required_env('AWS_ACCESS_KEY_ID'),
    secret_key = required_env('AWS_SECRET_ACCESS_KEY'),
  }

  return config
end

local function sha256_hex(data)
  return str.to_hex(digest.new('sha256'):final(data))
end

local function hmac_sha256(key, data)
  return hmac.new(key, 'sha256'):final(data)
end

-- Percent-encodes a path the way the signature algorithm requires: every
-- byte except unreserved characters and the slashes between segments. The
-- same encoding is used for the request that is sent, so that the storage
-- service sees exactly what was signed.
local function canonical_path(path)
  return (path:gsub('[^A-Za-z0-9%-%._~/]', function(c)
    return string.format('%%%02X', string.byte(c))
  end))
end

-- The signing key only depends on the date, so it is derived once a day.
local signing_key, signing_key_date

local function get_signing_key(conf, date)
  if signing_key_date ~= date then
    local key = hmac_sha256('AWS4' .. conf.secret_key, date)
    key = hmac_sha256(key, conf.region)
    key = hmac_sha256(key, 's3')
    signing_key = hmac_sha256(key, 'aws4_request')
    signing_key_date = date
  end

  return signing_key
end

-- Access phase handler. Replaces whatever the visitor sent with a signed GET
-- request for the file the current URI names, once `prefix` is removed.
function _M.sign_request(prefix)
  local method = ngx.req.get_method()

  if method ~= 'GET' and method ~= 'HEAD' then
    return ngx.exit(ngx.HTTP_NOT_ALLOWED)
  end

  local conf = get_config()

  -- Nothing the visitor sent is passed on to the storage service.
  for name, _ in pairs(ngx.req.get_headers(0, true)) do
    if not KEPT_HEADERS[name:lower()] then
      ngx.req.clear_header(name)
    end
  end

  ngx.req.set_uri_args({})
  ngx.req.discard_body()

  local path = canonical_path('/' .. conf.bucket .. '/' .. ngx.var.uri:sub(#prefix + 1))
  local now = ngx.time()
  local timestamp = os.date('!%Y%m%dT%H%M%SZ', now)
  local date = os.date('!%Y%m%d', now)
  local scope = date .. '/' .. conf.region .. '/s3/aws4_request'

  -- A HEAD request is fetched from storage with GET, so that the response
  -- can be cached.
  local canonical_request = 'GET\n'
    .. path .. '\n'
    .. '\n'
    .. 'host:' .. conf.host .. '\n'
    .. 'x-amz-content-sha256:' .. EMPTY_BODY_SHA256 .. '\n'
    .. 'x-amz-date:' .. timestamp .. '\n'
    .. '\n'
    .. SIGNED_HEADERS .. '\n'
    .. EMPTY_BODY_SHA256

  local string_to_sign = 'AWS4-HMAC-SHA256\n'
    .. timestamp .. '\n'
    .. scope .. '\n'
    .. sha256_hex(canonical_request)

  local signature = str.to_hex(hmac_sha256(get_signing_key(conf, date), string_to_sign))

  ngx.req.set_header('Authorization', 'AWS4-HMAC-SHA256 '
    .. 'Credential=' .. conf.access_key .. '/' .. scope
    .. ', SignedHeaders=' .. SIGNED_HEADERS
    .. ', Signature=' .. signature)
  ngx.req.set_header('x-amz-date', timestamp)
  ngx.req.set_header('x-amz-content-sha256', EMPTY_BODY_SHA256)

  ngx.var.s3_upstream = conf.upstream
  ngx.var.s3_host = conf.host
  ngx.var.s3_name = conf.name
  ngx.var.s3_path = path
end

-- Header filter. Removes what the storage service says about itself, and
-- sets the headers visitors should see.
function _M.response_headers()
  for name, _ in pairs(ngx.resp.get_headers(0, true)) do
    if name:lower():find('^x%-amz%-') then
      ngx.header[name] = nil
    end
  end

  ngx.header['Set-Cookie'] = nil
  ngx.header['Expires'] = nil
  ngx.header['Strict-Transport-Security'] = 'max-age=31556925'
  ngx.header['X-Content-Type-Options'] = 'nosniff'
  ngx.header['X-Cache-Status'] = ngx.var.upstream_cache_status

  if ngx.status ~= ngx.HTTP_OK and ngx.status ~= ngx.HTTP_PARTIAL_CONTENT then
    ngx.header['Cache-Control'] = 'no-store'
    return
  end

  local extension = ngx.var.uri:match('%.([A-Za-z0-9]+)$')

  ngx.header['Content-Type'] = CONTENT_TYPES[(extension or ''):lower()] or 'application/octet-stream'
  ngx.header['Cache-Control'] = 'public, max-age=315360000'

  if ngx.var.content_disposition ~= '' then
    ngx.header['Content-Disposition'] = ngx.var.content_disposition
  end
end

return _M
