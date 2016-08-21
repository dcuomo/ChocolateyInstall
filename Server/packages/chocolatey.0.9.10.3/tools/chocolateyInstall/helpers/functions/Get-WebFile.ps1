# http://poshcode.org/417
## Get-WebFile (aka wget for PowerShell)
##############################################################################################################
## Downloads a file or page from the web
## History:
## v3.6 - Add -Passthru switch to output TEXT files
## v3.5 - Add -Quiet switch to turn off the progress reports ...
## v3.4 - Add progress report for files which don't report size
## v3.3 - Add progress report for files which report their size
## v3.2 - Use the pure Stream object because StreamWriter is based on TextWriter:
##        it was messing up binary files, and making mistakes with extended characters in text
## v3.1 - Unwrap the filename when it has quotes around it
## v3   - rewritten completely using HttpWebRequest + HttpWebResponse to figure out the file name, if possible
## v2   - adds a ton of parsing to make the output pretty
##        added measuring the scripts involved in the command, (uses Tokenizer)
##############################################################################################################
## Additional functionality added by Chocolatey Team / Chocolatey Contributors
##  - Proxy
##  - Better error handling
##  - Inline documentation
##  - Cmdlet conversion
##  - Closing request/response and cleanup
##  - Request / ReadWriteResponse Timeouts
##############################################################################################################
function Get-WebFile {
<#
.SYNOPSIS
Downloads a file from an HTTP/HTTPS location. Prefer HTTPS when
available.

.DESCRIPTION
This will download a file from an HTTP/HTTPS location, saving the file
to the FileName location specified.

.NOTES
This is a low-level function and not recommended for use in package
scripts. It is recommended you call `Get-ChocolateyWebFile` instead.

Starting in 0.9.10, will automatically call Set-PowerShellExitCode to
set the package exit code to 404 if the resource is not found.

.INPUTS
None

.OUTPUTS
None

.PARAMETER Url
This is the url to download the file from. Prefer HTTPS when available.

.PARAMETER FileName
This is the full path to the file to create. If downloading to the
package folder next to the install script, the path will be like
`"$(Split-Path -Parent $MyInvocation.MyCommand.Definition)\\file.exe"`

.PARAMETER UserAgent
The user agent to use as part of the request. Defaults to 'chocolatey
command line'.

.PARAMETER PassThru
DO NOT USE - holdover from original function.

.PARAMETER Quiet
Silences the progress output.

.PARAMETER Options
OPTIONAL - Specify custom headers. Available in 0.9.10+.

.PARAMETER IgnoredArguments
Allows splatting with arguments that do not apply. Do not use directly.

.LINK
Get-ChocolateyWebFile

.LINK
Get-FtpFile

.LINK
Get-WebHeaders

.LINK
Get-WebFileName
#>
param(
  [parameter(Mandatory=$false, Position=0)][string] $url = '', #(Read-Host "The URL to download"),
  [parameter(Mandatory=$false, Position=1)][string] $fileName = $null,
  [parameter(Mandatory=$false, Position=2)][string] $userAgent = 'chocolatey command line',
  [parameter(Mandatory=$false)][switch] $Passthru,
  [parameter(Mandatory=$false)][switch] $quiet,
  [parameter(Mandatory=$false)][hashtable] $options = @{Headers=@{}},
  [parameter(ValueFromRemainingArguments = $true)][Object[]] $ignoredArguments
)
  Write-Debug "Running 'Get-WebFile' for $fileName with url:`'$url`', userAgent: `'$userAgent`' ";
  #if ($url -eq '' return)

  try {
    $uri = [System.Uri]$url
    if ($uri.IsFile()) {
      Write-Debug "Url is local file, setting destination"
      if ($url.LocalPath -ne $fileName) {
        Copy-Item $uri.LocalPath -Destination $fileName -Force
      }

      return
    }
  } catch {
    #continue on
  }

  $req = [System.Net.HttpWebRequest]::Create($url);
  $defaultCreds = [System.Net.CredentialCache]::DefaultCredentials
  if ($defaultCreds -ne $null) {
    $req.Credentials = $defaultCreds
  }

  $webclient = new-object System.Net.WebClient
  if ($defaultCreds -ne $null) {
    $webClient.Credentials = $defaultCreds
  }

  # check if a proxy is required
  $explicitProxy = $env:chocolateyProxyLocation
  $explicitProxyUser = $env:chocolateyProxyUser
  $explicitProxyPassword = $env:chocolateyProxyPassword
  if ($explicitProxy -ne $null) {
    # explicit proxy
	$proxy = New-Object System.Net.WebProxy($explicitProxy, $true)
	if ($explicitProxyPassword -ne $null) {
	  $passwd = ConvertTo-SecureString $explicitProxyPassword -AsPlainText -Force
	  $proxy.Credentials = New-Object System.Management.Automation.PSCredential ($explicitProxyUser, $passwd)
	}

	Write-Host "Using explicit proxy server '$explicitProxy'."
    $req.Proxy = $proxy

  } elseif (!$webclient.Proxy.IsBypassed($url))
  {
	# system proxy (pass through)
    $creds = [net.CredentialCache]::DefaultCredentials
    if ($creds -eq $null) {
      Write-Debug "Default credentials were null. Attempting backup method"
      $cred = get-credential
      $creds = $cred.GetNetworkCredential();
    }
    $proxyaddress = $webclient.Proxy.GetProxy($url).Authority
    Write-Host "Using system proxy server '$proxyaddress'."
    $proxy = New-Object System.Net.WebProxy($proxyaddress)
    $proxy.Credentials = $creds
    $req.Proxy = $proxy
  }

  $req.Accept = "*/*"
  $req.AllowAutoRedirect = $true
  $req.MaximumAutomaticRedirections = 20
  #$req.KeepAlive = $true
  $req.Timeout = 30000
  if ($env:chocolateyRequestTimeout -ne $null -and $env:chocolateyRequestTimeout -ne '') {
    Write-Debug "Setting request timeout to  $env:chocolateyRequestTimeout"
    $req.Timeout =  $env:chocolateyRequestTimeout
  }
  if ($env:chocolateyResponseTimeout -ne $null -and $env:chocolateyResponseTimeout -ne '') {
    Write-Debug "Setting read/write timeout to  $env:chocolateyResponseTimeout"
    $req.ReadWriteTimeout =  $env:chocolateyResponseTimeout
  }

  #http://stackoverflow.com/questions/518181/too-many-automatic-redirections-were-attempted-error-message-when-using-a-httpw
  $req.CookieContainer = New-Object System.Net.CookieContainer
  if ($userAgent -ne $null) {
    Write-Debug "Setting the UserAgent to `'$userAgent`'"
    $req.UserAgent = $userAgent
  }

  if ($options.Headers.Count -gt 0) {
    Write-Debug "Setting custom headers"
    foreach ($item in $options.Headers.GetEnumerator()) {
      $uri = (new-object system.uri $url)
      Write-Debug($item.Key + ':' + $item.Value)
      switch ($item.Key) {
        'Accept' {$req.Accept = $item.Value}
        'Cookie' {$req.CookieContainer.SetCookies($uri, $item.Value)}
        'Referer' {$req.Referer = $item.Value}
        'User-Agent' {$req.UserAgent = $item.Value}
        Default {$req.Headers.Add($item.Key, $item.Value)}
      }
    }
  }

  try {
   $res = $req.GetResponse();

   try {
      $headers = @{}
      foreach ($key in $res.Headers) {
        $value = $res.Headers[$key];
        if ($value) {
          $headers.Add("$key","$value")
        }
      }

      if ($headers.ContainsKey("Content-Type")) {
        $contentType = $headers['Content-Type']
        if ($contentType -ne $null) {
          if ($contentType.ToLower().Contains("text/html") -or $contentType.ToLower().Contains("text/plain")) {
            Write-Warning "$fileName is of content type $contentType"
            Set-Content -Path "$fileName.istext" -Value "$fileName has content type $contentType" -Encoding UTF8 -Force
          }
        }
      }
    } catch {
      # not able to get content-type header
      Write-Debug "Error getting content type - $($_.Exception.Message)"
    }

    if($fileName -and !(Split-Path $fileName)) {
      $fileName = Join-Path (Get-Location -PSProvider "FileSystem") $fileName
    }
    elseif((!$Passthru -and ($fileName -eq $null)) -or (($fileName -ne $null) -and (Test-Path -PathType "Container" $fileName)))
    {
      [string]$fileName = ([regex]'(?i)filename=(.*)$').Match( $res.Headers["Content-Disposition"] ).Groups[1].Value
      $fileName = $fileName.trim("\/""'")
      if(!$fileName) {
         $fileName = $res.ResponseUri.Segments[-1]
         $fileName = $fileName.trim("\/")
         if(!$fileName) {
            $fileName = Read-Host "Please provide a file name"
         }
         $fileName = $fileName.trim("\/")
         if(!([IO.FileInfo]$fileName).Extension) {
            $fileName = $fileName + "." + $res.ContentType.Split(";")[0].Split("/")[1]
         }
      }
      $fileName = Join-Path (Get-Location -PSProvider "FileSystem") $fileName
    }
    if($Passthru) {
      $encoding = [System.Text.Encoding]::GetEncoding( $res.CharacterSet )
      [string]$output = ""
    }

    if($res.StatusCode -eq 401 -or $res.StatusCode -eq 403 -or $res.StatusCode -eq 404) {
      $env:ChocolateyExitCode = $res.StatusCode
      throw "Remote file either doesn't exist, is unauthorized, or is forbidden for '$url'."
    }

    if($res.StatusCode -eq 200) {
      [long]$goal = $res.ContentLength
      $goalFormatted = Format-FileSize $goal
      $reader = $res.GetResponseStream()

      if ($fileName) {
        $fileDirectory = $([System.IO.Path]::GetDirectoryName($fileName))
        if (!(Test-Path($fileDirectory))) {
          [System.IO.Directory]::CreateDirectory($fileDirectory) | Out-Null
        }

        try {
          $writer = new-object System.IO.FileStream $fileName, "Create"
        } catch {
          throw $_.Exception
        }
      }

      [byte[]]$buffer = new-object byte[] 1048576
      [long]$total = [long]$count = [long]$iterLoop =0

      $originalEAP = $ErrorActionPreference
      $ErrorActionPreference = 'Stop'
      try {
        do
        {
          $count = $reader.Read($buffer, 0, $buffer.Length);
          if($fileName) {
            $writer.Write($buffer, 0, $count);
          }

          if($Passthru){
            $output += $encoding.GetString($buffer,0,$count)
          } elseif(!$quiet) {
            $total += $count
            $totalFormatted = Format-FileSize $total
            if($goal -gt 0 -and ++$iterLoop%10 -eq 0) {
              Write-Progress "Downloading $url to $fileName" "Saving $totalFormatted of $goalFormatted ($total/$goal)" -id 0 -percentComplete (($total/$goal)*100)
            }

            if ($total -eq $goal) {
              Write-Progress "Completed download of $url." "Completed download of $fileName ($goalFormatted)." -id 0 -Completed
            }
          }
        } while ($count -gt 0)
	    Write-Host ""
	    Write-Host "Download of $([System.IO.Path]::GetFileName($fileName)) ($goalFormatted) completed."
      } catch {
        throw $_.Exception
      } finally {
        $ErrorActionPreference = $originalEAP
      }

      $reader.Close()
      if($fileName) {
         $writer.Flush()
         $writer.Close()
      }
      if($Passthru){
         $output
      }
    }
  } catch {
    if ($req -ne $null) {
      $req.ServicePoint.MaxIdleTime = 0
      $req.Abort();
      # ruthlessly remove $req to ensure it isn't reused
      Remove-Variable req
      Start-Sleep 1
      [GC]::Collect()
    }

    Set-PowerShellExitCode 404
    if ($env:DownloadCacheAvailable -eq 'true') {
       throw "The remote file either doesn't exist, is unauthorized, or is forbidden for url '$url'. $($_.Exception.Message) `nThis package is likely not broken for licensed users - see https://chocolatey.org/docs/features-private-cdn."
    } else {
       throw "The remote file either doesn't exist, is unauthorized, or is forbidden for url '$url'. $($_.Exception.Message)"
    }
  } finally {
    if ($res -ne $null) {
      $res.Close()
    }

    Start-Sleep 1
  }
}

# this could be cleaned up with http://learn-powershell.net/2013/02/08/powershell-and-events-object-events/

# SIG # Begin signature block
# MIIcrQYJKoZIhvcNAQcCoIIcnjCCHJoCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDg7xA9wUrozzDh
# gxALmIwRNrZ1Ho9FQznvulGPdsLItKCCF7cwggUwMIIEGKADAgECAhAECRgbX9W7
# ZnVTQ7VvlVAIMA0GCSqGSIb3DQEBCwUAMGUxCzAJBgNVBAYTAlVTMRUwEwYDVQQK
# EwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xJDAiBgNV
# BAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0xMzEwMjIxMjAwMDBa
# Fw0yODEwMjIxMjAwMDBaMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lD
# ZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EwggEiMA0GCSqGSIb3
# DQEBAQUAA4IBDwAwggEKAoIBAQD407Mcfw4Rr2d3B9MLMUkZz9D7RZmxOttE9X/l
# qJ3bMtdx6nadBS63j/qSQ8Cl+YnUNxnXtqrwnIal2CWsDnkoOn7p0WfTxvspJ8fT
# eyOU5JEjlpB3gvmhhCNmElQzUHSxKCa7JGnCwlLyFGeKiUXULaGj6YgsIJWuHEqH
# CN8M9eJNYBi+qsSyrnAxZjNxPqxwoqvOf+l8y5Kh5TsxHM/q8grkV7tKtel05iv+
# bMt+dDk2DZDv5LVOpKnqagqrhPOsZ061xPeM0SAlI+sIZD5SlsHyDxL0xY4PwaLo
# LFH3c7y9hbFig3NBggfkOItqcyDQD2RzPJ6fpjOp/RnfJZPRAgMBAAGjggHNMIIB
# yTASBgNVHRMBAf8ECDAGAQH/AgEAMA4GA1UdDwEB/wQEAwIBhjATBgNVHSUEDDAK
# BggrBgEFBQcDAzB5BggrBgEFBQcBAQRtMGswJAYIKwYBBQUHMAGGGGh0dHA6Ly9v
# Y3NwLmRpZ2ljZXJ0LmNvbTBDBggrBgEFBQcwAoY3aHR0cDovL2NhY2VydHMuZGln
# aWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEUm9vdENBLmNydDCBgQYDVR0fBHow
# eDA6oDigNoY0aHR0cDovL2NybDQuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJl
# ZElEUm9vdENBLmNybDA6oDigNoY0aHR0cDovL2NybDMuZGlnaWNlcnQuY29tL0Rp
# Z2lDZXJ0QXNzdXJlZElEUm9vdENBLmNybDBPBgNVHSAESDBGMDgGCmCGSAGG/WwA
# AgQwKjAoBggrBgEFBQcCARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzAK
# BghghkgBhv1sAzAdBgNVHQ4EFgQUWsS5eyoKo6XqcQPAYPkt9mV1DlgwHwYDVR0j
# BBgwFoAUReuir/SSy4IxLVGLp6chnfNtyA8wDQYJKoZIhvcNAQELBQADggEBAD7s
# DVoks/Mi0RXILHwlKXaoHV0cLToaxO8wYdd+C2D9wz0PxK+L/e8q3yBVN7Dh9tGS
# dQ9RtG6ljlriXiSBThCk7j9xjmMOE0ut119EefM2FAaK95xGTlz/kLEbBw6RFfu6
# r7VRwo0kriTGxycqoSkoGjpxKAI8LpGjwCUR4pwUR6F6aGivm6dcIFzZcbEMj7uo
# +MUSaJ/PQMtARKUT8OZkDCUIQjKyNookAv4vcn4c10lFluhZHen6dGRrsutmQ9qz
# sIzV6Q3d9gEgzpkxYz0IGhizgZtPxpMQBvwHgfqL2vmCSfdibqFT+hKUGIUukpHq
# aGxEMrJmoecYpJpkUe8wggVAMIIEKKADAgECAhAHdGbtomdvOuySF9IwU3EQMA0G
# CSqGSIb3DQEBCwUAMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2VydCBJ
# bmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lDZXJ0
# IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0EwHhcNMTYwMzI0MDAwMDAw
# WhcNMTcwMzI4MTIwMDAwWjB9MQswCQYDVQQGEwJVUzEPMA0GA1UECBMGS2Fuc2Fz
# MQ8wDQYDVQQHEwZUb3Bla2ExJTAjBgNVBAoTHFJlYWxEaW1lbnNpb25zIFNvZnR3
# YXJlLCBMTEMxJTAjBgNVBAMTHFJlYWxEaW1lbnNpb25zIFNvZnR3YXJlLCBMTEMw
# ggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC52YS2WKUpBtdkDyJ3G0Qm
# 42v+W+yqr7DediVzIeCjHpKNkmmxO8+lS+nniFDjoFGO1JG/G3ZywVRFlM1LKHeP
# M1eON6wT0H1gvhxpMzyuC/SRW9wvMtTlvHnjdTLW06Oe9tvGkQkTM8rbzwRDIZ9o
# ddT8BxHSOmGelrAN9CwKf60ziw8jKLZnuAuZwSgkX5K7wvOs8viqydlnt7z3Wyim
# L+wjue85Mpa7jyjIfnUqssN1qz4nce+e89CxTD2AbWjGwnfTcTgmj3EUSJRQgDRk
# J+O/sVzS/V76xajLoPvI4ZlAsMpeK3ptLYqviU3ZaNUzLQWFjuWqc3fhjbWDFF51
# AgMBAAGjggHFMIIBwTAfBgNVHSMEGDAWgBRaxLl7KgqjpepxA8Bg+S32ZXUOWDAd
# BgNVHQ4EFgQUT0GgvxvwrOqMjXQ8yw7QDagIVJ4wDgYDVR0PAQH/BAQDAgeAMBMG
# A1UdJQQMMAoGCCsGAQUFBwMDMHcGA1UdHwRwMG4wNaAzoDGGL2h0dHA6Ly9jcmwz
# LmRpZ2ljZXJ0LmNvbS9zaGEyLWFzc3VyZWQtY3MtZzEuY3JsMDWgM6Axhi9odHRw
# Oi8vY3JsNC5kaWdpY2VydC5jb20vc2hhMi1hc3N1cmVkLWNzLWcxLmNybDBMBgNV
# HSAERTBDMDcGCWCGSAGG/WwDATAqMCgGCCsGAQUFBwIBFhxodHRwczovL3d3dy5k
# aWdpY2VydC5jb20vQ1BTMAgGBmeBDAEEATCBhAYIKwYBBQUHAQEEeDB2MCQGCCsG
# AQUFBzABhhhodHRwOi8vb2NzcC5kaWdpY2VydC5jb20wTgYIKwYBBQUHMAKGQmh0
# dHA6Ly9jYWNlcnRzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydFNIQTJBc3N1cmVkSURD
# b2RlU2lnbmluZ0NBLmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IB
# AQAD6K2ldfDx7hOZxW6smYkiV4lxXY4bewxGv/gh2hjWgLiQ/sornz2fHDni/kOf
# qhn8/3KvYd4V33QqMqjm/qsRpwjj9NC/Q2BGuTg0ax3e/Z9ZIvcYB4xx8CRbGKse
# R9lixgMAJZMCWyGzAC/E3XX+BX3B6y8N5zBIKRY1M7xub+LM7zW9LGMhX3e56J7G
# UF7zIzQ7ZkaJzfxFbVvEz2/KNoNGiCmA7Y0biMXpX9730Dbg4Z+B4SUe4k4WPLS/
# 3goAq8lVMFtoqShvyvrmYtj2gFjQmH3BzSCSRZrAFbWYDCga57Fq7A4xrF2i67kG
# oljzeP+/35wuoOlrggn2EuJ1MIIGajCCBVKgAwIBAgIQAwGaAjr/WLFr1tXq5hfw
# ZjANBgkqhkiG9w0BAQUFADBiMQswCQYDVQQGEwJVUzEVMBMGA1UEChMMRGlnaUNl
# cnQgSW5jMRkwFwYDVQQLExB3d3cuZGlnaWNlcnQuY29tMSEwHwYDVQQDExhEaWdp
# Q2VydCBBc3N1cmVkIElEIENBLTEwHhcNMTQxMDIyMDAwMDAwWhcNMjQxMDIyMDAw
# MDAwWjBHMQswCQYDVQQGEwJVUzERMA8GA1UEChMIRGlnaUNlcnQxJTAjBgNVBAMT
# HERpZ2lDZXJ0IFRpbWVzdGFtcCBSZXNwb25kZXIwggEiMA0GCSqGSIb3DQEBAQUA
# A4IBDwAwggEKAoIBAQCjZF38fLPggjXg4PbGKuZJdTvMbuBTqZ8fZFnmfGt/a4yd
# VfiS457VWmNbAklQ2YPOb2bu3cuF6V+l+dSHdIhEOxnJ5fWRn8YUOawk6qhLLJGJ
# zF4o9GS2ULf1ErNzlgpno75hn67z/RJ4dQ6mWxT9RSOOhkRVfRiGBYxVh3lIRvfK
# Do2n3k5f4qi2LVkCYYhhchhoubh87ubnNC8xd4EwH7s2AY3vJ+P3mvBMMWSN4+v6
# GYeofs/sjAw2W3rBerh4x8kGLkYQyI3oBGDbvHN0+k7Y/qpA8bLOcEaD6dpAoVk6
# 2RUJV5lWMJPzyWHM0AjMa+xiQpGsAsDvpPCJEY93AgMBAAGjggM1MIIDMTAOBgNV
# HQ8BAf8EBAMCB4AwDAYDVR0TAQH/BAIwADAWBgNVHSUBAf8EDDAKBggrBgEFBQcD
# CDCCAb8GA1UdIASCAbYwggGyMIIBoQYJYIZIAYb9bAcBMIIBkjAoBggrBgEFBQcC
# ARYcaHR0cHM6Ly93d3cuZGlnaWNlcnQuY29tL0NQUzCCAWQGCCsGAQUFBwICMIIB
# Vh6CAVIAQQBuAHkAIAB1AHMAZQAgAG8AZgAgAHQAaABpAHMAIABDAGUAcgB0AGkA
# ZgBpAGMAYQB0AGUAIABjAG8AbgBzAHQAaQB0AHUAdABlAHMAIABhAGMAYwBlAHAA
# dABhAG4AYwBlACAAbwBmACAAdABoAGUAIABEAGkAZwBpAEMAZQByAHQAIABDAFAA
# LwBDAFAAUwAgAGEAbgBkACAAdABoAGUAIABSAGUAbAB5AGkAbgBnACAAUABhAHIA
# dAB5ACAAQQBnAHIAZQBlAG0AZQBuAHQAIAB3AGgAaQBjAGgAIABsAGkAbQBpAHQA
# IABsAGkAYQBiAGkAbABpAHQAeQAgAGEAbgBkACAAYQByAGUAIABpAG4AYwBvAHIA
# cABvAHIAYQB0AGUAZAAgAGgAZQByAGUAaQBuACAAYgB5ACAAcgBlAGYAZQByAGUA
# bgBjAGUALjALBglghkgBhv1sAxUwHwYDVR0jBBgwFoAUFQASKxOYspkH7R7for5X
# DStnAs0wHQYDVR0OBBYEFGFaTSS2STKdSip5GoNL9B6Jwcp9MH0GA1UdHwR2MHQw
# OKA2oDSGMmh0dHA6Ly9jcmwzLmRpZ2ljZXJ0LmNvbS9EaWdpQ2VydEFzc3VyZWRJ
# RENBLTEuY3JsMDigNqA0hjJodHRwOi8vY3JsNC5kaWdpY2VydC5jb20vRGlnaUNl
# cnRBc3N1cmVkSURDQS0xLmNybDB3BggrBgEFBQcBAQRrMGkwJAYIKwYBBQUHMAGG
# GGh0dHA6Ly9vY3NwLmRpZ2ljZXJ0LmNvbTBBBggrBgEFBQcwAoY1aHR0cDovL2Nh
# Y2VydHMuZGlnaWNlcnQuY29tL0RpZ2lDZXJ0QXNzdXJlZElEQ0EtMS5jcnQwDQYJ
# KoZIhvcNAQEFBQADggEBAJ0lfhszTbImgVybhs4jIA+Ah+WI//+x1GosMe06Fxlx
# F82pG7xaFjkAneNshORaQPveBgGMN/qbsZ0kfv4gpFetW7easGAm6mlXIV00Lx9x
# sIOUGQVrNZAQoHuXx/Y/5+IRQaa9YtnwJz04HShvOlIJ8OxwYtNiS7Dgc6aSwNOO
# Mdgv420XEwbu5AO2FKvzj0OncZ0h3RTKFV2SQdr5D4HRmXQNJsQOfxu19aDxxncG
# KBXp2JPlVRbwuwqrHNtcSCdmyKOLChzlldquxC5ZoGHd2vNtomHpigtt7BIYvfdV
# VEADkitrwlHCCkivsNRu4PQUCjob4489yq9qjXvc2EQwggbNMIIFtaADAgECAhAG
# /fkDlgOt6gAK6z8nu7obMA0GCSqGSIb3DQEBBQUAMGUxCzAJBgNVBAYTAlVTMRUw
# EwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20x
# JDAiBgNVBAMTG0RpZ2lDZXJ0IEFzc3VyZWQgSUQgUm9vdCBDQTAeFw0wNjExMTAw
# MDAwMDBaFw0yMTExMTAwMDAwMDBaMGIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxE
# aWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xITAfBgNVBAMT
# GERpZ2lDZXJ0IEFzc3VyZWQgSUQgQ0EtMTCCASIwDQYJKoZIhvcNAQEBBQADggEP
# ADCCAQoCggEBAOiCLZn5ysJClaWAc0Bw0p5WVFypxNJBBo/JM/xNRZFcgZ/tLJz4
# FlnfnrUkFcKYubR3SdyJxArar8tea+2tsHEx6886QAxGTZPsi3o2CAOrDDT+GEmC
# /sfHMUiAfB6iD5IOUMnGh+s2P9gww/+m9/uizW9zI/6sVgWQ8DIhFonGcIj5BZd9
# o8dD3QLoOz3tsUGj7T++25VIxO4es/K8DCuZ0MZdEkKB4YNugnM/JksUkK5ZZgrE
# jb7SzgaurYRvSISbT0C58Uzyr5j79s5AXVz2qPEvr+yJIvJrGGWxwXOt1/HYzx4K
# dFxCuGh+t9V3CidWfA9ipD8yFGCV/QcEogkCAwEAAaOCA3owggN2MA4GA1UdDwEB
# /wQEAwIBhjA7BgNVHSUENDAyBggrBgEFBQcDAQYIKwYBBQUHAwIGCCsGAQUFBwMD
# BggrBgEFBQcDBAYIKwYBBQUHAwgwggHSBgNVHSAEggHJMIIBxTCCAbQGCmCGSAGG
# /WwAAQQwggGkMDoGCCsGAQUFBwIBFi5odHRwOi8vd3d3LmRpZ2ljZXJ0LmNvbS9z
# c2wtY3BzLXJlcG9zaXRvcnkuaHRtMIIBZAYIKwYBBQUHAgIwggFWHoIBUgBBAG4A
# eQAgAHUAcwBlACAAbwBmACAAdABoAGkAcwAgAEMAZQByAHQAaQBmAGkAYwBhAHQA
# ZQAgAGMAbwBuAHMAdABpAHQAdQB0AGUAcwAgAGEAYwBjAGUAcAB0AGEAbgBjAGUA
# IABvAGYAIAB0AGgAZQAgAEQAaQBnAGkAQwBlAHIAdAAgAEMAUAAvAEMAUABTACAA
# YQBuAGQAIAB0AGgAZQAgAFIAZQBsAHkAaQBuAGcAIABQAGEAcgB0AHkAIABBAGcA
# cgBlAGUAbQBlAG4AdAAgAHcAaABpAGMAaAAgAGwAaQBtAGkAdAAgAGwAaQBhAGIA
# aQBsAGkAdAB5ACAAYQBuAGQAIABhAHIAZQAgAGkAbgBjAG8AcgBwAG8AcgBhAHQA
# ZQBkACAAaABlAHIAZQBpAG4AIABiAHkAIAByAGUAZgBlAHIAZQBuAGMAZQAuMAsG
# CWCGSAGG/WwDFTASBgNVHRMBAf8ECDAGAQH/AgEAMHkGCCsGAQUFBwEBBG0wazAk
# BggrBgEFBQcwAYYYaHR0cDovL29jc3AuZGlnaWNlcnQuY29tMEMGCCsGAQUFBzAC
# hjdodHRwOi8vY2FjZXJ0cy5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURS
# b290Q0EuY3J0MIGBBgNVHR8EejB4MDqgOKA2hjRodHRwOi8vY3JsMy5kaWdpY2Vy
# dC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMDqgOKA2hjRodHRwOi8v
# Y3JsNC5kaWdpY2VydC5jb20vRGlnaUNlcnRBc3N1cmVkSURSb290Q0EuY3JsMB0G
# A1UdDgQWBBQVABIrE5iymQftHt+ivlcNK2cCzTAfBgNVHSMEGDAWgBRF66Kv9JLL
# gjEtUYunpyGd823IDzANBgkqhkiG9w0BAQUFAAOCAQEARlA+ybcoJKc4HbZbKa9S
# z1LpMUerVlx71Q0LQbPv7HUfdDjyslxhopyVw1Dkgrkj0bo6hnKtOHisdV0XFzRy
# R4WUVtHruzaEd8wkpfMEGVWp5+Pnq2LN+4stkMLA0rWUvV5PsQXSDj0aqRRbpoYx
# YqioM+SbOafE9c4deHaUJXPkKqvPnHZL7V/CSxbkS3BMAIke/MV5vEwSV/5f4R68
# Al2o/vsHOE8Nxl2RuQ9nRc3Wg+3nkg2NsWmMT/tZ4CMP0qquAHzunEIOz5HXJ7cW
# 7g/DvXwKoO4sCFWFIrjrGBpN/CohrUkxg0eVd3HcsRtLSxwQnHcUwZ1PL1qVCCkQ
# JjGCBEwwggRIAgEBMIGGMHIxCzAJBgNVBAYTAlVTMRUwEwYDVQQKEwxEaWdpQ2Vy
# dCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20xMTAvBgNVBAMTKERpZ2lD
# ZXJ0IFNIQTIgQXNzdXJlZCBJRCBDb2RlIFNpZ25pbmcgQ0ECEAd0Zu2iZ2867JIX
# 0jBTcRAwDQYJYIZIAWUDBAIBBQCggYQwGAYKKwYBBAGCNwIBDDEKMAigAoAAoQKA
# ADAZBgkqhkiG9w0BCQMxDAYKKwYBBAGCNwIBBDAcBgorBgEEAYI3AgELMQ4wDAYK
# KwYBBAGCNwIBFTAvBgkqhkiG9w0BCQQxIgQg9PmmhiorYvBPwmUHNudJ2IqmACXr
# DSjnWRnRSBqXmJUwDQYJKoZIhvcNAQEBBQAEggEADzjjdTjdSzaQ5ldXMaXvDisC
# yS14a4pDDL4njjNJmgtbaqXnaa072yO3vwMJe21P8FXtWTAypdhVIgRYi9LEs8tE
# 7h8E9gUsM8yF4rPXUK0tPB5KQreoa/Bh67HmjtGFyRwHLyiQQZFQQmf/DfyDTyVa
# 4zRXiB2gaElld4OPXtj9z2588HI1tTazFcRZz4WtYx2elM1pLkflpNQ3rbVTgCLD
# X4TR4GvHbYEZapewB3dLtUB1raAkHnUj1P9eKb1wkGc4egT7iLDrw54UAJyIAN49
# fOB2+d/409f1Haansik43eWM0iTw0xtoDncE/xFP6L188sCGdF/YHsciVwBjZ6GC
# Ag8wggILBgkqhkiG9w0BCQYxggH8MIIB+AIBATB2MGIxCzAJBgNVBAYTAlVTMRUw
# EwYDVQQKEwxEaWdpQ2VydCBJbmMxGTAXBgNVBAsTEHd3dy5kaWdpY2VydC5jb20x
# ITAfBgNVBAMTGERpZ2lDZXJ0IEFzc3VyZWQgSUQgQ0EtMQIQAwGaAjr/WLFr1tXq
# 5hfwZjAJBgUrDgMCGgUAoF0wGAYJKoZIhvcNAQkDMQsGCSqGSIb3DQEHATAcBgkq
# hkiG9w0BCQUxDxcNMTYwNjIzMjA1MzAzWjAjBgkqhkiG9w0BCQQxFgQUHuWL7q3t
# EgwcEVx8Q1Bq5OfyW2gwDQYJKoZIhvcNAQEBBQAEggEALbLOCirz19fzI1HIgN1z
# FyKzQgPM1RKS/iAj+bxD9C51PfFMsCGlxM6oiLn3s4LFHlzcsmRMMwtoXdEnR/EV
# Dlfczznz+5ZrKf8ba4C392tMrIAn08TU6WFg/l+65cM7sDhg7MSOToM7CD7C2pLG
# SPl7emUbsGt2EojIaXDQDnK21x+6pZ+WVblgorKlQWtpMI2YqAxGlTw7sHZIP79J
# 5SETejlRz6NrN+IULYtQ1nABUEM/eJnzv4J/M8Wtnz2dKaqXWx2Jg2RlYJdfN9Ay
# DlYTxuGtJX6xLll4SHUVqNS+UKRjHF0QgmeFvXUzcMw7ngS90hYZF5b1TaTCrNmY
# UA==
# SIG # End signature block
