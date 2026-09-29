# OpenApi.Generator.Script

This package distributes `GenerateNetSdkFromOpenApi.ps1` for reuse from any .NET project.

After adding a `PackageReference`, the script path is available as:

- `$(GenerateNetSdkFromOpenApiScriptPath)`

## Usage example

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <ItemGroup>
    <PackageReference Include="OpenApi.Generator.Script" Version="1.0.0" PrivateAssets="all" />
  </ItemGroup>

  <Target Name="GenerateSdkFromOpenApi">
    <Exec Command="pwsh -File &quot;$(GenerateNetSdkFromOpenApiScriptPath)&quot; -OpenApiDocumentPath &quot;$(MSBuildProjectDirectory)\openapi.json&quot; -OutputDirectoryPath &quot;$(MSBuildProjectDirectory)\GeneratedSdk&quot;" />
  </Target>
</Project>
```
