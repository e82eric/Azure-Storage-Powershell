$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$sut = (Split-Path -Leaf $MyInvocation.MyCommand.Path).Replace(".tests.", ".")
. "$here\$sut"

$storageName = "account1"
$version = "version1"
$retryCount = 2
$clientType = "type1"
$defaultScheme = "scheme1"
$storageName = "account1"

$patcher = new_options_patcher $storageName $version $retryCount $clientType $defaultScheme $storageName

Describe "the url is not provided in the options" {
	It "uses the storage name in the url" {
		$options = @{ Resource = "resource1" }
		$patcher.execute($options)
		$options.Url | should equal "scheme1://account1.type1.core.windows.net/resource1" 
	}
	It "uses the client type in the url" {
		$options = @{ Resource = "resource1" }
		$patcher.execute($options)
		$options.Url | should equal "scheme1://account1.type1.core.windows.net/resource1" 
	}
	Context "when the scheme is not set" {
		$options = @{ Resource = "resource1" }
		$patcher.execute($options)
		It "sets the scheme to the default" {
			$options.Scheme | should equal $defaultScheme 
		}
		It "uses the default scheme in the url" {
			$options.Url | should equal "scheme1://account1.type1.core.windows.net/resource1" 
		}
	}
	Context "when the scheme is set" {
		$scheme = "scheme2"
		$options = @{ Scheme = $scheme; Resource = "resource1" }
		$patcher.execute($options)
		It "it does not set the scheme" {
			$options.Scheme | should equal $scheme 
		}
		It "uses the scheme in the url" {
			$options.Url | should equal "scheme2://account1.type1.core.windows.net/resource1" 
		}
	}
	Context "version is not set" {
		$options = @{ }
		$patcher.execute($options)
		It "sets the version to the default" {
			$options.Version | should equal "version1" 
		}
	}
	Context "version is set" {
		$options = @{ Version = "version2" }
		$patcher.execute($options)
		It "sets the version to the default" {
			$options.Version | should equal "version2" 
		}
	}
	Context "retry count is not set" {
		$options = @{ }
		$patcher.execute($options)
		It "sets the retry count to the default" {
			$options.RetryCount | should equal 2 
		}
	}
	Context "retry count is set" {
		$options = @{ RetryCount = 3 }
		$patcher.execute($options)
		It "sets the retry count to the default" {
			$options.RetryCount | should equal 3 
		}
	}
}

Describe "the url is the only option" {
	Context "only the url is provided" {
		$options = @{ Url = "url1" }
		$patcher.execute($options)
		It "uses the url" {
			$options.Url | should equal "url1"
		}
	}
	Context "the url and resource are provided" {
		$options = @{ Url = "url1"; Resouce = "resource1" }
		$patcher.execute($options)
		It "uses the url" {
			$options.Url | should equal "url1"
		}
	}
}