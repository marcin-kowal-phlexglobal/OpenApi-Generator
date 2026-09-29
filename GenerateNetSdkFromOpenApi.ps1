param(
	[Parameter(Mandatory = $true)]
	[string]$OpenApiDocumentPath,
	[Parameter(Mandatory = $true)]
	[string]$OutputDirectoryPath
)

function SetupPrerequisites()
{
	RemoveOpenApiGeneratorCliImage

	if ((docker ps 2>&1) -match '^(?!error)')
	{
		Write-Host "Docker is running" -ForegroundColor black -BackgroundColor green
	}
	else
	{
		Write-Host "Docker not running." -ForegroundColor red -BackgroundColor black
		Write-Host "Please start Docker." -ForegroundColor red -BackgroundColor black
		Exit
	}
}

function RemoveOpenApiGeneratorCliImage()
{
	$cleanupMarkerPath = Join-Path $PSScriptRoot ".openapi-generator-cli-cleanup.timestamp"
	$cleanupIntervalHours = 12
	$now = Get-Date
	$shouldCleanup = $true

	if (Test-Path -Path $cleanupMarkerPath)
	{
		$lastCleanupRaw = Get-Content -Path $cleanupMarkerPath -ErrorAction SilentlyContinue | Select-Object -First 1
		$lastCleanup = [DateTime]::MinValue
		if ([DateTime]::TryParse($lastCleanupRaw, [ref]$lastCleanup))
		{
			$hoursSinceLastCleanup = ($now - $lastCleanup).TotalHours
			if ($hoursSinceLastCleanup -lt $cleanupIntervalHours)
			{
				Write-Host "Skipping OpenAPI generator image cleanup. Last cleanup was less than $cleanupIntervalHours hours ago." -ForegroundColor yellow -BackgroundColor black
				$shouldCleanup = $false
			}
		}
	}

	if (-Not $shouldCleanup)
	{
		return
	}

	$imageName = "openapitools/openapi-generator-cli"
	Write-Host "Removing Docker image: $imageName" -ForegroundColor black -BackgroundColor green

	$existingImage = docker images --format "{{.Repository}}" | Select-String -SimpleMatch $imageName
	if ($null -ne $existingImage)
	{
		docker image rm -f $imageName | Out-Null
		Write-Host "Removed Docker image: $imageName" -ForegroundColor black -BackgroundColor green
	}
	else
	{
		Write-Host "Docker image not found: $imageName" -ForegroundColor yellow -BackgroundColor black
	}

	$now.ToString("o") | Set-Content -Path $cleanupMarkerPath
}

function GetSdkPackageName()
{
	Param(
		[string]$OutputFullPath
	)

	$existingProjectPath = GetOutputProjectFilePath -OutputFullPath $OutputFullPath
	if ($null -ne $existingProjectPath)
	{
		return [System.IO.Path]::GetFileNameWithoutExtension($existingProjectPath)
	}

	$outputDirectoryName = Split-Path -Path $OutputFullPath -Leaf
	if ([string]::IsNullOrWhiteSpace($outputDirectoryName))
	{
		return "Generated.Sdk.Net"
	}

	$parts = $outputDirectoryName.Split(@("-", "_", ".", " "), [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object {
		if ($_.Length -gt 0)
		{
			$_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1)
		}
	}

	$sanitizedName = ($parts -join "")
	if ([string]::IsNullOrWhiteSpace($sanitizedName))
	{
		$sanitizedName = "Generated"
	}

	return "$sanitizedName.Sdk.Net"
}

function GetApiName()
{
	Param(
		[string]$OutputFullPath
	)

	$projectPath = GetOutputProjectFilePath -OutputFullPath $OutputFullPath
	$projectName = $null
	if ($null -ne $projectPath)
	{
		$projectName = [System.IO.Path]::GetFileNameWithoutExtension($projectPath)
	}
	else
	{
		$projectName = GetSdkPackageName -OutputFullPath $OutputFullPath
	}

	$projectBaseName = $projectName -replace '\.Sdk\.Net(Core)?$', ''
	if ([string]::IsNullOrWhiteSpace($projectBaseName))
	{
		$projectBaseName = $projectName
	}

	$nameParts = $projectBaseName -split '[^A-Za-z0-9]+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
	$normalizedBaseName = ($nameParts | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }) -join ''
	if ([string]::IsNullOrWhiteSpace($normalizedBaseName))
	{
		$normalizedBaseName = "Default"
	}

	return "$normalizedBaseName`Api"
}

function ResolveOpenApiDocumentPath()
{
	Param(
		[string]$Path
	)

	if (-Not (Test-Path -Path $Path -PathType Leaf))
	{
		Write-Host "OpenAPI document does not exist: $Path" -ForegroundColor red -BackgroundColor black
		Exit
	}

	$resolvedPath = (Resolve-Path -Path $Path).Path

	$allowedExtensions = @(".json", ".yaml", ".yml")
	$extension = [System.IO.Path]::GetExtension($resolvedPath).ToLowerInvariant()
	if ($allowedExtensions -notcontains $extension)
	{
		Write-Host "OpenAPI document must be .json, .yaml, or .yml: $resolvedPath" -ForegroundColor red -BackgroundColor black
		Exit
	}

	return $resolvedPath
}

function ResolvePotentialRelativePath()
{
	Param(
		[string]$Value,
		[string]$BaseDirectory
	)

	if ([System.IO.Path]::IsPathRooted($Value))
	{
		return $Value
	}

	return Join-Path $BaseDirectory $Value
}

function CollapseCaseDuplicateProperties()
{
	Param(
		$Node
	)

	if ($Node -is [System.Collections.IDictionary])
	{
		$result = [ordered]@{}
		foreach ($key in @($Node.Keys))
		{
			$value = CollapseCaseDuplicateProperties -Node $Node[$key]
			if ($key -eq "properties" -and $value -is [System.Collections.IDictionary])
			{
				$dedupedProperties = [ordered]@{}
				$seen = @{}
				foreach ($propertyName in @($value.Keys))
				{
					$normalizedPropertyName = $propertyName.ToLowerInvariant()
					if ($seen.ContainsKey($normalizedPropertyName))
					{
						$previousPropertyName = $seen[$normalizedPropertyName]
						$null = $dedupedProperties.Remove($previousPropertyName)
					}

					$dedupedProperties[$propertyName] = $value[$propertyName]
					$seen[$normalizedPropertyName] = $propertyName
				}

				$value = $dedupedProperties
			}

			$result[$key] = $value
		}

		return $result
	}

	if ($Node -is [System.Collections.IList] -and -not ($Node -is [string]))
	{
		$items = @()
		foreach ($item in $Node)
		{
			$items += , (CollapseCaseDuplicateProperties -Node $item)
		}

		return $items
	}

	return $Node
}

function PrepareOpenApiSpecForGeneration()
{
	Param(
		[string]$SpecPath
	)

	$extension = [System.IO.Path]::GetExtension($SpecPath).ToLowerInvariant()
	if ($extension -ne ".json")
	{
		return $SpecPath
	}

	$rawSpec = Get-Content -Path $SpecPath -Raw
	$parsedSpec = $rawSpec | ConvertFrom-Json -AsHashtable
	$sanitizedSpec = CollapseCaseDuplicateProperties -Node $parsedSpec

	$tempFileName = "openapi-sanitized-$([guid]::NewGuid().ToString('N')).json"
	$tempSpecPath = Join-Path ([System.IO.Path]::GetTempPath()) $tempFileName
	$sanitizedSpec | ConvertTo-Json -Depth 100 | Set-Content -Path $tempSpecPath -Encoding UTF8

	Write-Host "Created sanitized OpenAPI spec for generation: $tempSpecPath"
	return $tempSpecPath
}

function ResolveOpenApiInputs()
{
	Param(
		[string]$InputPath
	)

	$resolvedInputPath = ResolveOpenApiDocumentPath -Path $InputPath
	$rawContent = Get-Content -Path $resolvedInputPath -Raw

	$isOpenApiSpec = $false
	if (
		$rawContent -match '(?im)^\s*openapi\s*:' -or
		$rawContent -match '(?im)^\s*swagger\s*:' -or
		$rawContent -match '(?im)^\s*paths\s*:' -or
		$rawContent -match '(?im)"openapi"\s*:' -or
		$rawContent -match '(?im)"swagger"\s*:' -or
		$rawContent -match '(?im)"paths"\s*:'
	)
	{
		$isOpenApiSpec = $true
	}

	if ($isOpenApiSpec)
	{
		return [PSCustomObject]@{
			SpecPath = $resolvedInputPath
			ConfigPath = $null
		}
	}

	$configPath = $resolvedInputPath
	$configDirectory = Split-Path -Path $configPath -Parent

	$inputSpecMatch = [regex]::Match($rawContent, '(?im)^\s*inputSpec\s*:\s*(.+?)\s*$')
	if ($inputSpecMatch.Success)
	{
		$rawSpecPath = $inputSpecMatch.Groups[1].Value.Trim().Trim("'`"")
		$candidateSpecPath = ResolvePotentialRelativePath -Value $rawSpecPath -BaseDirectory $configDirectory
		if (Test-Path -Path $candidateSpecPath -PathType Leaf)
		{
			return [PSCustomObject]@{
				SpecPath = (Resolve-Path -Path $candidateSpecPath).Path
				ConfigPath = $configPath
			}
		}
	}

	$siblingSpecCandidates = @("swagger.json", "openapi.json", "openapi.yaml", "openapi.yml")
	foreach ($candidateFileName in $siblingSpecCandidates)
	{
		$candidatePath = Join-Path $configDirectory $candidateFileName
		if (Test-Path -Path $candidatePath -PathType Leaf)
		{
			return [PSCustomObject]@{
				SpecPath = (Resolve-Path -Path $candidatePath).Path
				ConfigPath = $configPath
			}
		}
	}

	$repoRoot = Split-Path -Path $configDirectory -Parent
	$srcPath = Join-Path $repoRoot "src"
	if (Test-Path -Path $srcPath -PathType Container)
	{
		$apiSpecCandidate = Get-ChildItem -Path $srcPath -Filter "*.Api.json" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -ne $apiSpecCandidate)
		{
			return [PSCustomObject]@{
				SpecPath = $apiSpecCandidate.FullName
				ConfigPath = $configPath
			}
		}
	}

	Write-Host "The provided file appears to be an OpenAPI generator config, but no OpenAPI spec was found via inputSpec, sibling files, or src\*.Api.json." -ForegroundColor red -BackgroundColor black
	Exit
}

function ResolveOutputDirectoryPath()
{
	Param(
		[string]$Path
	)

	if (-Not (Test-Path -Path $Path))
	{
		New-Item -Path $Path -ItemType Directory | Out-Null
	}

	$resolvedPath = (Resolve-Path -Path $Path).Path
	return $resolvedPath
}

function GetOutputProjectFilePath()
{
	Param(
		[string]$OutputFullPath
	)

	$projectFiles = @(Get-ChildItem -Path $OutputFullPath -Filter "*.csproj" -File -ErrorAction SilentlyContinue)
	if ($projectFiles.Count -eq 1)
	{
		return $projectFiles[0].FullName
	}

	if ($projectFiles.Count -gt 1)
	{
		$preferred = $projectFiles | Where-Object { $_.Name -like "*.Sdk.Net.csproj" } | Select-Object -First 1
		if ($null -ne $preferred)
		{
			return $preferred.FullName
		}

		Write-Host "Multiple project files found in $OutputFullPath. Unable to determine which one to use." -ForegroundColor red -BackgroundColor black
		Exit
	}

	return $null
}

function GetGeneratedProjectDirectory()
{
	Param(
		[string]$OutputFullPath
	)

	$tempPath = Join-Path $OutputFullPath "temp"
	if (-Not (Test-Path -Path $tempPath -PathType Container))
	{
		Write-Host "Temporary generation directory not found: $tempPath" -ForegroundColor red -BackgroundColor black
		Exit
	}

	$generatedProjectFile = Get-ChildItem -Path $tempPath -Recurse -Filter "*.csproj" -File -ErrorAction SilentlyContinue | Select-Object -First 1
	if ($null -eq $generatedProjectFile)
	{
		$srcRoot = Join-Path $tempPath "src"
		$firstSourceDirectory = Get-ChildItem -Path $srcRoot -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
		if ($null -eq $firstSourceDirectory)
		{
			Write-Host "No generated source directory was found under $tempPath." -ForegroundColor red -BackgroundColor black
			Exit
		}

		return $firstSourceDirectory.FullName
	}

	return $generatedProjectFile.Directory.FullName
}

function GenerateNetCoreWithOpenApi()
{
	Param(
		[string]$OpenApiFullPath,
		[string]$OpenApiConfigPath,
		[string]$OutputFullPath
	)

	$packagename = GetSdkPackageName -OutputFullPath $OutputFullPath
	$apiName = GetApiName -OutputFullPath $OutputFullPath
	$specDirectory = Split-Path -Path $OpenApiFullPath -Parent
	$specFile = Split-Path -Path $OpenApiFullPath -Leaf
	$configMountArgument = ""
	$configGeneratorArgument = ""

	Write-Host "Generating NetCore files with OpenApi" -ForegroundColor black -BackgroundColor green

	if (-not [string]::IsNullOrWhiteSpace($OpenApiConfigPath))
	{
		$configDirectory = Split-Path -Path $OpenApiConfigPath -Parent
		$configFile = Split-Path -Path $OpenApiConfigPath -Leaf
		$configMountArgument = " -v `"$configDirectory\:/config`""
		$configGeneratorArgument = " -c /config/$configFile"
	}

	$cmd = "docker run --rm -v `"$specDirectory\:/openapi`" -v `"$OutputFullPath\:/output`"$configMountArgument openapitools/openapi-generator-cli generate -i /openapi/$specFile -g csharp -o /output/temp --library httpclient --additional-properties=packageName=$packagename,apiName=$apiName,netCoreProjectFile=true,targetFramework=net10.0 --global-property apiDocs=false,modelDocs=false,apiTests=false,modelTests=false --skip-validate-spec$configGeneratorArgument"
	Write-Host $cmd
	Invoke-Expression $cmd
	if ($LASTEXITCODE -ne 0)
	{
		Write-Host "OpenAPI generation failed." -ForegroundColor red -BackgroundColor black
		Exit $LASTEXITCODE
	}

	Write-Host "Generating NetCore finished" -ForegroundColor black -BackgroundColor green
}

# Adds packages that are required, but not added by autogeneration.
# This is to support custom extensions in the package, and
# to consolidate versions across the solution.
function AddExtraDotNetPackages()
{
	Param(
		[string]$OutputFullPath
	)

	$additionalDotNetPackages = @(
		[PSCustomObject]@{ Name = "Microsoft.IdentityModel.Tokens"; Version = "8.14.0" }
		[PSCustomObject]@{ Name = "Polly"; Version = "8.6.4" })

	$csProjPath = GetOutputProjectFilePath -OutputFullPath $OutputFullPath
	if ($null -eq $csProjPath -or -Not (Test-Path -Path $csProjPath -PathType Leaf))
	{
		Write-Host "No project file exists in $OutputFullPath." -ForegroundColor red -BackgroundColor black
		Exit
	}

	Write-Host "Installing extra packages to: $csProjPath"
	foreach ($package in $additionalDotNetPackages)
	{
		dotnet add package $package.Name --version $package.Version --project $csProjPath -s https://api.nuget.org/v3/index.json
		if ($LASTEXITCODE -ne 0)
		{
			Write-Host "Failed to add package $($package.Name)." -ForegroundColor red -BackgroundColor black
			Exit $LASTEXITCODE
		}
	}

	Write-Host "Finished installing packages" -ForegroundColor black -BackgroundColor green
}

function BuildGeneratedProject()
{
	Param(
		[string]$OutputFullPath
	)

	$csProjPath = GetOutputProjectFilePath -OutputFullPath $OutputFullPath
	if ($null -eq $csProjPath -or -Not (Test-Path -Path $csProjPath -PathType Leaf))
	{
		Write-Host "No project file exists in $OutputFullPath." -ForegroundColor red -BackgroundColor black
		Exit
	}

	Write-Host "Building generated project: $csProjPath"
	dotnet build $csProjPath -nologo
	if ($LASTEXITCODE -ne 0)
	{
		Write-Host "Generated project build failed." -ForegroundColor red -BackgroundColor black
		Exit $LASTEXITCODE
	}

	Write-Host "Generated project build succeeded" -ForegroundColor black -BackgroundColor green
}

function EnsureSdkProjectFile()
{
	Param(
		[string]$OutputFullPath
	)

	$existingProjectPath = GetOutputProjectFilePath -OutputFullPath $OutputFullPath
	if ($null -ne $existingProjectPath)
	{
		Write-Host "Project file already exists: $existingProjectPath"
		return
	}

	$defaultProjectName = GetSdkPackageName -OutputFullPath $OutputFullPath
	$csProjPath = Join-Path $OutputFullPath "$defaultProjectName.csproj"

	$csFiles = Get-ChildItem -Path $OutputFullPath -Filter "*.cs" -File -Recurse -ErrorAction SilentlyContinue
	if ($null -eq $csFiles -or $csFiles.Count -eq 0)
	{
		Write-Host "No C# files found in $OutputFullPath. Cannot create SDK project file." -ForegroundColor red -BackgroundColor black
		Exit
	}

	$csProjContent = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net9.0</TargetFramework>
    <ImplicitUsings>enable</ImplicitUsings>
    <Nullable>enable</Nullable>
    <AssemblyName>$defaultProjectName</AssemblyName>
    <RootNamespace>$defaultProjectName</RootNamespace>
    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>
  </PropertyGroup>
  <ItemGroup>
    <Compile Include="**\*.cs" />
  </ItemGroup>
</Project>
"@

	Set-Content -Path $csProjPath -Value $csProjContent -Encoding UTF8
	Write-Host "Created project file: $csProjPath" -ForegroundColor black -BackgroundColor green
}

function RemoveFiles()
{
	Param(
		[string]$OutputFullPath
	)

	Write-Host "Removing redundant files"

	$existingItems = Get-ChildItem -Path $OutputFullPath -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "temp" }
	foreach ($existingItem in $existingItems)
	{
		Remove-Item -Path $existingItem.FullName -Recurse -Force
	}

	$generatedProjectDirectory = GetGeneratedProjectDirectory -OutputFullPath $OutputFullPath
	$path = Join-Path $generatedProjectDirectory "*"
	Copy-Item -Path $path -Destination $OutputFullPath -Force -Recurse
	$removesrc = Join-Path $OutputFullPath "temp"
	Remove-Item -Recurse -Force $removesrc

	Write-Host "Removing files finished"
}

function ApplyApiClassNameFromProjectName()
{
	Param(
		[string]$OutputFullPath
	)

	$apiName = GetApiName -OutputFullPath $OutputFullPath
	$apiDirectory = Join-Path $OutputFullPath "Api"
	if (-not (Test-Path -Path $apiDirectory -PathType Container))
	{
		return
	}

	$defaultApiPath = Join-Path $apiDirectory "DefaultApi.cs"
	$targetApiPath = Join-Path $apiDirectory "$apiName.cs"
	if (Test-Path -Path $defaultApiPath -PathType Leaf)
	{
		if (Test-Path -Path $targetApiPath -PathType Leaf)
		{
			Remove-Item -Path $targetApiPath -Force
		}

		Rename-Item -Path $defaultApiPath -NewName "$apiName.cs"
	}

	$sourceFiles = Get-ChildItem -Path $OutputFullPath -Filter "*.cs" -File -Recurse -ErrorAction SilentlyContinue
	foreach ($sourceFile in $sourceFiles)
	{
		$fileContent = Get-Content -Path $sourceFile.FullName -Raw
		$updatedContent = $fileContent -replace '\bIDefaultApi\b', "I$apiName" -replace '\bDefaultApi\b', $apiName
		if ($updatedContent -ne $fileContent)
		{
			Set-Content -Path $sourceFile.FullName -Value $updatedContent -Encoding UTF8
		}
	}
}

$resolvedOpenApiInputs = ResolveOpenApiInputs -InputPath $OpenApiDocumentPath
$resolvedOutputPath = ResolveOutputDirectoryPath -Path $OutputDirectoryPath
$generationSpecPath = PrepareOpenApiSpecForGeneration -SpecPath $resolvedOpenApiInputs.SpecPath

try
{
	SetupPrerequisites
	GenerateNetCoreWithOpenApi -OpenApiFullPath $generationSpecPath -OpenApiConfigPath $resolvedOpenApiInputs.ConfigPath -OutputFullPath $resolvedOutputPath
	RemoveFiles -OutputFullPath $resolvedOutputPath
	ApplyApiClassNameFromProjectName -OutputFullPath $resolvedOutputPath
	EnsureSdkProjectFile -OutputFullPath $resolvedOutputPath
	AddExtraDotNetPackages -OutputFullPath $resolvedOutputPath
	BuildGeneratedProject -OutputFullPath $resolvedOutputPath
}
finally
{
	if ($generationSpecPath -ne $resolvedOpenApiInputs.SpecPath -and (Test-Path -Path $generationSpecPath -PathType Leaf))
	{
		Remove-Item -Path $generationSpecPath -Force
	}
}
