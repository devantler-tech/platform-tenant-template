# Builds the ASP.NET Core application and runs it on the ASP.NET runtime image.
#
# It matches deploy/deployment.yaml: the app listens on port 3000 (the PORT
# variable) and runs as the non-root user 1000 on a read-only root filesystem
# with a writable /tmp.
FROM mcr.microsoft.com/dotnet/sdk:11.0 AS build
WORKDIR /src
COPY global.json .editorconfig ./
COPY src/ src/
RUN dotnet publish src/Example/Example.csproj --configuration Release --output /out

FROM mcr.microsoft.com/dotnet/aspnet:11.0
WORKDIR /app
COPY --from=build /out .
# The diagnostics IPC channel would try to write outside /tmp; the app does not need it.
ENV DOTNET_EnableDiagnostics=0
EXPOSE 3000
USER 1000
ENTRYPOINT ["dotnet", "Example.dll"]
