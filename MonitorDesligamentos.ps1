Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
#  DICIONARIO DE STATUS CODES (traducao)
# ============================================================
$script:StatusDesc = @{
    "0x0"        = "Sucesso"
    "0xC0000064" = "Usuario nao existe"
    "0xC000006A" = "Senha incorreta"
    "0xC000006D" = "Falha na autenticacao (usuario/senha)"
    "0xC000006E" = "Restricao de conta"
    "0xC000006F" = "Restricao de horario"
    "0xC0000070" = "Restricao de estacao de trabalho"
    "0xC0000071" = "Senha expirada"
    "0xC0000072" = "Conta desabilitada"
    "0xC0000133" = "Diferenca de horario entre cliente e servidor"
    "0xC000015B" = "Tipo de logon nao concedido"
    "0xC000018C" = "Dominio confiante falhou"
    "0xC0000193" = "Conta expirada"
    "0xC0000224" = "Senha deve ser alterada no proximo logon"
    "0xC0000234" = "Conta bloqueada"
    "0xC0000413" = "Autenticacao bloqueada por firewall"
    "0xC0000371" = "Sem credenciais locais"
    "0xC000005E" = "Sem logon servers disponiveis"
    "0xC0000192" = "Trust relationship falhou"
    "0xC0000380" = "Smartcard invalido"
    "0xC0000381" = "Smartcard sem certificado valido"
}

function Get-StatusDescricao {
    param([string]$Codigo)
    if ([string]::IsNullOrWhiteSpace($Codigo)) { return "" }
    $cod = $Codigo.Trim().ToUpper()
    if ($script:StatusDesc.ContainsKey($cod)) { return $script:StatusDesc[$cod] }
    return "Codigo desconhecido"
}

# ============================================================
#  CONFIGURACAO PERSISTENTE
# ============================================================
$script:BaseDir = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Join-Path $env:LOCALAPPDATA "MonitorDesligamentos"
} else {
    $PSScriptRoot
}

if (-not (Test-Path $script:BaseDir)) {
    try { New-Item -ItemType Directory -Path $script:BaseDir -Force | Out-Null }
    catch { $script:BaseDir = $env:TEMP }
}

$script:ConfigPath = Join-Path $script:BaseDir "MonitorConfig.json"

function Carregar-Config {
    $default = [PSCustomObject]@{
        Dias          = 30
        UsuariosCred  = "bituser;bitbar"
        IntervaloMin  = 5
        AlertaAtivo   = $true
        UltimoPdf     = ""
    }
    if (Test-Path $script:ConfigPath) {
        try {
            $json = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
            foreach ($p in $default.PSObject.Properties.Name) {
                if ($null -ne $json.$p) { $default.$p = $json.$p }
            }
        } catch { }
    }
    return $default
}

function Salvar-Config {
    param($Config)
    try { $Config | ConvertTo-Json | Set-Content -Path $script:ConfigPath -Encoding UTF8 } catch { }
}

$script:Config = Carregar-Config

# ============================================================
#  PDFPIG 0.1.8 - download automatico (compativel com PS 5.1)
# ============================================================
function Garantir-PdfPig {
    $libDir = Join-Path $script:BaseDir "lib"
    if (-not (Test-Path $libDir)) {
        New-Item -ItemType Directory -Path $libDir -Force | Out-Null
    }

    $dllPrincipal = Join-Path $libDir "UglyToad.PdfPig.dll"
    $dllCore      = Join-Path $libDir "UglyToad.PdfPig.Core.dll"
    $dllFonts     = Join-Path $libDir "UglyToad.PdfPig.Fonts.dll"

    # Se ja temos as 3 DLLs, carrega
    if ((Test-Path $dllPrincipal) -and (Test-Path $dllCore) -and (Test-Path $dllFonts)) {
        try {
            Add-Type -Path $dllCore -ErrorAction Stop
            Add-Type -Path $dllFonts -ErrorAction Stop
            Add-Type -Path $dllPrincipal -ErrorAction Stop
            return $dllPrincipal
        }
        catch {
            Remove-Item $dllPrincipal -Force -ErrorAction SilentlyContinue
            Remove-Item $dllCore -Force -ErrorAction SilentlyContinue
            Remove-Item $dllFonts -Force -ErrorAction SilentlyContinue
        }
    }

    # Versao 0.1.8 - ultima com netstandard2.0 (compativel com PS 5.1)
    $urls = @(
        "https://www.nuget.org/api/v2/package/PdfPig/0.1.8",
        "https://globalcdn.nuget.org/packages/pdfpig.0.1.8.nupkg"
    )

    $statusLabel.Text = "Baixando PdfPig 0.1.8 (primeira vez)..."
    $form.Refresh()

    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

    $nupkgPath = $null
    $erros = @()

    foreach ($url in $urls) {
        try {
            $tempNupkg = Join-Path $libDir ("pdfpig_" + [Guid]::NewGuid().ToString("N") + ".nupkg")
            Invoke-WebRequest -Uri $url -OutFile $tempNupkg -UseBasicParsing -TimeoutSec 90 -ErrorAction Stop

            if ((Get-Item $tempNupkg).Length -gt 50000) {
                $nupkgPath = $tempNupkg
                break
            }
            else {
                Remove-Item $tempNupkg -Force -ErrorAction SilentlyContinue
                $erros += "Arquivo muito pequeno em '$url'"
            }
        }
        catch {
            $erros += "Falha em '$url': $($_.Exception.Message)"
        }
    }

    if (-not $nupkgPath) {
        $msg = "Nao foi possivel baixar o PdfPig.`r`n`r`nTentativas:`r`n" + ($erros -join "`r`n")
        $statusLabel.Text = "Falha ao baixar PdfPig."
        [System.Windows.Forms.MessageBox]::Show($msg, "Erro PdfPig", "OK", "Error") | Out-Null
        return $null
    }

    # Extrai
    try {
        $extractDir = Join-Path $libDir "pdfpig_extract"
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue }

        $zipPath = $nupkgPath -replace '\.nupkg$', '.zip'
        Move-Item $nupkgPath $zipPath -Force
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

        # Pasta netstandard2.0
        $pastaAlvo = Get-ChildItem -Path $extractDir -Recurse -Directory |
            Where-Object { $_.Name -eq "netstandard2.0" } |
            Select-Object -First 1

        if (-not $pastaAlvo) {
            $pastaAlvo = Get-ChildItem -Path $extractDir -Recurse -Directory |
                Where-Object { $_.FullName -match '\\lib\\' } |
                Select-Object -First 1
        }

        if (-not $pastaAlvo) {
            throw "Nao encontrei a pasta de DLLs no pacote"
        }

        $dlls = Get-ChildItem -Path $pastaAlvo.FullName -Filter "*.dll"
        foreach ($dll in $dlls) {
            $destino = Join-Path $libDir $dll.Name
            Copy-Item $dll.FullName $destino -Force
        }

        Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue

        if ((Test-Path $dllPrincipal) -and (Test-Path $dllCore) -and (Test-Path $dllFonts)) {
            Add-Type -Path $dllCore -ErrorAction Stop
            Add-Type -Path $dllFonts -ErrorAction Stop
            Add-Type -Path $dllPrincipal -ErrorAction Stop
            $statusLabel.Text = "PdfPig carregado com sucesso."
            return $dllPrincipal
        }
        else {
            $found = (Get-ChildItem $libDir -Filter '*.dll' | ForEach-Object { $_.Name }) -join "`r`n"
            $msg = "PdfPig foi extraido mas faltam DLLs.`r`n`r`nEncontradas:`r`n$found"
            [System.Windows.Forms.MessageBox]::Show($msg, "Erro PdfPig", "OK", "Error") | Out-Null
            return $null
        }
    }
    catch {
        $msg = "Erro ao extrair PdfPig:`r`n`r`n$($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($msg, "Erro PdfPig", "OK", "Error") | Out-Null
        return $null
    }
}

# ============================================================
#  PARSER DO LOG PDF
# ============================================================
$script:SecoesConhecidas = @(
    "Abertura","Fechamento","Clientes","Fiscal","Receive",
    "Sincronizacao","Editando","Sangria","Suprimento"
)

function Extrair-TextoPdfPig {
    param([string]$CaminhoPdf)

    try {
        $doc = [UglyToad.PdfPig.PdfDocument]::Open($CaminhoPdf)
        $sb = New-Object System.Text.StringBuilder

        foreach ($pagina in $doc.GetPages()) {
            try {
                [void]$sb.AppendLine($pagina.Text)
            }
            catch {
                try {
                    $palavras = $pagina.GetWords()
                    $linhaAtual = ""
                    foreach ($p in $palavras) {
                        $linhaAtual += "$($p.Text) "
                    }
                    [void]$sb.AppendLine($linhaAtual)
                }
                catch {
                    [void]$sb.AppendLine("(erro ao extrair pagina)")
                }
            }
        }

        $doc.Dispose()
        return $sb.ToString()
    }
    catch {
        $script:UltimoErroPdf = $_.Exception.ToString()
        return $null
    }
}

function Parse-LogBitBar {
    param([string]$TextoCompleto)

    $registros = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($TextoCompleto)) { return $registros }

    # O texto do PdfPig pode vir sem quebras de linha entre as colunas/registros.
    # Insere uma quebra antes de cada registro reconhecível (usuario + tipo + computador + hora).
    $tipos = 'Geral|Inserindo|Editando|Libera|Fiscal|Receive|Sincronizacao|Abertura|Fechamento|Clientes|Itens|Bloqueio|Pagamento'
    $inicioRegistro = '(?=[\p{L}][\p{L}\p{N}._'' -]*?(?:' + $tipos + ')[\p{L}\p{N}._-]*\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
    $textoNormalizado = [regex]::Replace($TextoCompleto, $inicioRegistro, "`n")

    # Cabeçalhos de seção também podem estar grudados no registro anterior.
    $textoNormalizado = [regex]::Replace(
        $textoNormalizado,
        '(?=(?:Abertura|Fechamento|Clientes|Fiscal|Receive|Sincronizacao|Editando|Sangria|Suprimento|Itens|Libera Cartao/Mesa)UsuárioTipoComputadorDescriçãoHora)',
        "`n"
    )

    $linhas = $textoNormalizado -split "`r?`n"
    $secaoAtual = "Geral"

    $regexColado = [regex]'^(?:(?<data>\d{2}/\d{2}/\d{4}))?(?<usuario>[\p{L}][\p{L}\p{N}._'' -]*?)(?<tipo>Geral|Inserindo|Editando|Libera|Fiscal|Receive|Sincronizacao|Abertura|Fechamento|Clientes|Itens|Bloqueio|Pagamento)(?<comp>[\p{L}\p{N}._-]*?)(?<hora>\d{2}:\d{2}:\d{2}(?:\.\d+)?)(?<desc>.*)$'
    $regexComEspacos = [regex]'^(?:(?<data>\d{2}/\d{2}/\d{4})\s*)?(?<usuario>[\p{L}][\p{L}\p{N}._'' -]*?)\s+(?<tipo>[\p{L}]+)\s+(?<comp>[\p{L}\p{N}._-]+)?\s*(?<hora>\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s*(?<desc>.*)$'

    foreach ($linhaBruta in $linhas) {
        $linha = $linhaBruta.Trim()
        if (-not $linha) { continue }

        if ($linha -match '^(Abertura|Fechamento|Clientes|Fiscal|Itens|Receive|Sincronizacao|Sangria|Suprimento|Libera Cartao/Mesa)$') {
            $secaoAtual = $Matches[1]
            continue
        }
        if ($linha -match '^(UsuárioTipoComputadorDescriçãoHora|Usu.rioTipoComputadorDescri..oHora|Página:|Log de Alterações)') { continue }

        $m = $regexColado.Match($linha)
        if (-not $m.Success) { $m = $regexComEspacos.Match($linha) }
        if (-not $m.Success) { continue }

        $data = $m.Groups['data'].Value
        $hora = $m.Groups['hora'].Value
        $user = $m.Groups['usuario'].Value.Trim()
        $tipo = $m.Groups['tipo'].Value
        $comp = $m.Groups['comp'].Value
        $desc = $m.Groups['desc'].Value.Trim()

        # Evita interpretar cabeçalhos/ruído como evento.
        if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($hora)) { continue }

        $jsonPayload = $null
        $jsonMatch = [regex]::Match($desc, '\{.*\}')
        if ($jsonMatch.Success) {
            try { $jsonPayload = $jsonMatch.Value | ConvertFrom-Json } catch { $jsonPayload = $null }
        }

        [void]$registros.Add([PSCustomObject]@{
            Secao = $secaoAtual
            Data = $data
            Hora = $hora
            DataHora = if ($data) { "$data $hora" } else { $hora }
            Usuario = $user
            Computador = $comp
            Tipo = $tipo
            Descricao = $desc
            Payload = $jsonPayload
        })
    }

    return $registros
}

# ============================================================
#  FUNCAO AUXILIAR: GRID PADRAO
# ============================================================
function New-GridPadrao {
    param([int]$X, [int]$Y, [int]$W, [int]$H)
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Location = New-Object System.Drawing.Point($X, $Y)
    $g.Size = New-Object System.Drawing.Size($W, $H)
    $g.ReadOnly = $true
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.AllowUserToResizeRows = $false
    $g.AllowUserToResizeColumns = $true
    $g.SelectionMode = "FullRowSelect"
    $g.MultiSelect = $false
    $g.AutoSizeColumnsMode = "DisplayedCells"
    $g.AutoSizeRowsMode = "None"
    $g.RowHeadersVisible = $false
    $g.Anchor = "Top,Bottom,Left,Right"
    $g.BackgroundColor = [System.Drawing.Color]::White
    $g.BorderStyle = "FixedSingle"
    $g.EnableHeadersVisualStyles = $false
    $g.ScrollBars = "Both"
    $g.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(45, 45, 48)
    $g.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $g.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    try {
        $prop = [System.Windows.Forms.DataGridView].GetProperty("DoubleBuffered",
            [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance)
        $prop.SetValue($g, $true, $null)
    } catch { }
    return $g
}

# ============================================================
#  POPUP DE DETALHES (JSON formatado)
# ============================================================
function Show-DetalhesJson {
    param(
        [string]$Titulo,
        [string]$JsonText
    )

    $popup = New-Object System.Windows.Forms.Form
    $popup.Text = $Titulo
    $popup.Size = New-Object System.Drawing.Size(920, 720)
    $popup.StartPosition = "CenterParent"
    $popup.MinimizeBox = $false
    $popup.MaximizeBox = $true
    $popup.FormBorderStyle = "Sizable"
    $popup.ShowInTaskbar = $false

    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Multiline = $true
    $txt.ReadOnly = $true
    $txt.ScrollBars = "Both"
    $txt.WordWrap = $false
    $txt.Dock = "Fill"
    $txt.Font = New-Object System.Drawing.Font("Consolas", 9.5)
    $txt.BackColor = [System.Drawing.Color]::White
    $txt.ForeColor = [System.Drawing.Color]::Black
    $txt.Text = $JsonText
    $txt.Select(0, 0)

    $btnFechar = New-Object System.Windows.Forms.Button
    $btnFechar.Text = "Fechar"
    $btnFechar.Dock = "Bottom"
    $btnFechar.Height = 38
    $btnFechar.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnFechar.Add_Click({ $popup.Close() })

    $popup.Controls.Add($txt)
    $popup.Controls.Add($btnFechar)
    $popup.AcceptButton = $btnFechar
    $popup.CancelButton = $btnFechar

    [void]$popup.ShowDialog()
    $popup.Dispose()
}

# ============================================================
#  FORMULARIO PRINCIPAL
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "Monitor de Eventos"
$form.Size = New-Object System.Drawing.Size(1350, 850)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(1100, 650)

# ============================================================
#  CONTROLES DE TOPO
# ============================================================
$lblPeriodo = New-Object System.Windows.Forms.Label
$lblPeriodo.Text = "Ultimos (dias):"
$lblPeriodo.Location = New-Object System.Drawing.Point(10, 12)
$lblPeriodo.Size = New-Object System.Drawing.Size(90, 20)

$numDias = New-Object System.Windows.Forms.NumericUpDown
$numDias.Location = New-Object System.Drawing.Point(100, 10)
$numDias.Size = New-Object System.Drawing.Size(60, 24)
$numDias.Minimum = 0
$numDias.Maximum = 3650
$numDias.Value = [int]$script:Config.Dias

$btnAtualizarTudo = New-Object System.Windows.Forms.Button
$btnAtualizarTudo.Text = "Atualizar"
$btnAtualizarTudo.Location = New-Object System.Drawing.Point(170, 9)
$btnAtualizarTudo.Size = New-Object System.Drawing.Size(90, 26)

$btnLimparAlertas = New-Object System.Windows.Forms.Button
$btnLimparAlertas.Text = "Limpar Alertas"
$btnLimparAlertas.Location = New-Object System.Drawing.Point(265, 9)
$btnLimparAlertas.Size = New-Object System.Drawing.Size(115, 26)

$lblIntervalo = New-Object System.Windows.Forms.Label
$lblIntervalo.Text = "Auto (min):"
$lblIntervalo.Location = New-Object System.Drawing.Point(395, 12)
$lblIntervalo.Size = New-Object System.Drawing.Size(70, 20)

$numIntervalo = New-Object System.Windows.Forms.NumericUpDown
$numIntervalo.Location = New-Object System.Drawing.Point(465, 10)
$numIntervalo.Size = New-Object System.Drawing.Size(55, 24)
$numIntervalo.Minimum = 1
$numIntervalo.Maximum = 1440
$numIntervalo.Value = [int]$script:Config.IntervaloMin

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = "Auto-atualizar"
$chkAuto.Location = New-Object System.Drawing.Point(530, 12)
$chkAuto.Size = New-Object System.Drawing.Size(110, 22)
$chkAuto.Checked = [bool]$script:Config.AlertaAtivo

# ============================================================
#  ABAS
# ============================================================
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(10, 45)
$tabs.Size = New-Object System.Drawing.Size(1315, 740)
$tabs.Anchor = "Top,Bottom,Left,Right"

# ============================================================
#  ABA 1 - DESLIGAMENTOS
# ============================================================
$tabDesligamentos = New-Object System.Windows.Forms.TabPage
$tabDesligamentos.Text = "Desligamentos"
$tabDesligamentos.BackColor = [System.Drawing.Color]::White

$lblFiltroDesl = New-Object System.Windows.Forms.Label
$lblFiltroDesl.Text = "Filtrar por ID:"
$lblFiltroDesl.Location = New-Object System.Drawing.Point(10, 15)
$lblFiltroDesl.Size = New-Object System.Drawing.Size(80, 20)

$cmbFiltroDesl = New-Object System.Windows.Forms.ComboBox
$cmbFiltroDesl.Location = New-Object System.Drawing.Point(95, 13)
$cmbFiltroDesl.Size = New-Object System.Drawing.Size(200, 24)
$cmbFiltroDesl.DropDownStyle = "DropDownList"
[void]$cmbFiltroDesl.Items.Add("Todos")
[void]$cmbFiltroDesl.Items.Add("41 - Kernel-Power")
[void]$cmbFiltroDesl.Items.Add("6008 - Desligamento Inesperado")
[void]$cmbFiltroDesl.Items.Add("1001 - BSOD")
[void]$cmbFiltroDesl.Items.Add("1074 - Desligamento Planejado")
$cmbFiltroDesl.SelectedIndex = 0

$lblResumoDesl = New-Object System.Windows.Forms.Label
$lblResumoDesl.Location = New-Object System.Drawing.Point(310, 17)
$lblResumoDesl.Size = New-Object System.Drawing.Size(980, 20)
$lblResumoDesl.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblResumoDesl.Anchor = "Top,Left,Right"

$gridDesl = New-GridPadrao -X 10 -Y 50 -W 1280 -H 650

$tabDesligamentos.Controls.Add($lblFiltroDesl)
$tabDesligamentos.Controls.Add($cmbFiltroDesl)
$tabDesligamentos.Controls.Add($lblResumoDesl)
$tabDesligamentos.Controls.Add($gridDesl)

# ============================================================
#  ABA 2 - CREDENCIAIS
# ============================================================
$tabCredenciais = New-Object System.Windows.Forms.TabPage
$tabCredenciais.Text = "Credenciais de Rede"
$tabCredenciais.BackColor = [System.Drawing.Color]::White

$lblFiltroCred = New-Object System.Windows.Forms.Label
$lblFiltroCred.Text = "ID:"
$lblFiltroCred.Location = New-Object System.Drawing.Point(10, 15)
$lblFiltroCred.Size = New-Object System.Drawing.Size(25, 20)

$cmbFiltroCred = New-Object System.Windows.Forms.ComboBox
$cmbFiltroCred.Location = New-Object System.Drawing.Point(40, 13)
$cmbFiltroCred.Size = New-Object System.Drawing.Size(200, 24)
$cmbFiltroCred.DropDownStyle = "DropDownList"
[void]$cmbFiltroCred.Items.Add("Todos")
[void]$cmbFiltroCred.Items.Add("4625 - Falha de Logon")
[void]$cmbFiltroCred.Items.Add("4776 - Validacao de Credenciais")
[void]$cmbFiltroCred.Items.Add("4740 - Conta Bloqueada")
$cmbFiltroCred.SelectedIndex = 0

$lblUsuarioCred = New-Object System.Windows.Forms.Label
$lblUsuarioCred.Text = "Usuario:"
$lblUsuarioCred.Location = New-Object System.Drawing.Point(250, 15)
$lblUsuarioCred.Size = New-Object System.Drawing.Size(55, 20)

$txtUsuarioCred = New-Object System.Windows.Forms.TextBox
$txtUsuarioCred.Location = New-Object System.Drawing.Point(305, 13)
$txtUsuarioCred.Size = New-Object System.Drawing.Size(150, 24)
$txtUsuarioCred.Text = $script:Config.UsuariosCred

$lblBuscaCred = New-Object System.Windows.Forms.Label
$lblBuscaCred.Text = "Buscar (IP/Wks):"
$lblBuscaCred.Location = New-Object System.Drawing.Point(465, 15)
$lblBuscaCred.Size = New-Object System.Drawing.Size(95, 20)

$txtBuscaCred = New-Object System.Windows.Forms.TextBox
$txtBuscaCred.Location = New-Object System.Drawing.Point(560, 13)
$txtBuscaCred.Size = New-Object System.Drawing.Size(160, 24)
$txtBuscaCred.Text = ""

$lblResumoCred = New-Object System.Windows.Forms.Label
$lblResumoCred.Location = New-Object System.Drawing.Point(730, 17)
$lblResumoCred.Size = New-Object System.Drawing.Size(560, 20)
$lblResumoCred.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblResumoCred.Anchor = "Top,Left,Right"

$gridCred = New-GridPadrao -X 10 -Y 50 -W 1280 -H 650

$tabCredenciais.Controls.Add($lblFiltroCred)
$tabCredenciais.Controls.Add($cmbFiltroCred)
$tabCredenciais.Controls.Add($lblUsuarioCred)
$tabCredenciais.Controls.Add($txtUsuarioCred)
$tabCredenciais.Controls.Add($lblBuscaCred)
$tabCredenciais.Controls.Add($txtBuscaCred)
$tabCredenciais.Controls.Add($lblResumoCred)
$tabCredenciais.Controls.Add($gridCred)

# ============================================================
#  ABA 3 - IMPRESSORAS
# ============================================================
$tabImpressoras = New-Object System.Windows.Forms.TabPage
$tabImpressoras.Text = "Impressoras"
$tabImpressoras.BackColor = [System.Drawing.Color]::White

$lblModoImp = New-Object System.Windows.Forms.Label
$lblModoImp.Text = "Modo:"
$lblModoImp.Location = New-Object System.Drawing.Point(10, 15)
$lblModoImp.Size = New-Object System.Drawing.Size(40, 20)

$cmbModoImp = New-Object System.Windows.Forms.ComboBox
$cmbModoImp.Location = New-Object System.Drawing.Point(55, 13)
$cmbModoImp.Size = New-Object System.Drawing.Size(200, 24)
$cmbModoImp.DropDownStyle = "DropDownList"
[void]$cmbModoImp.Items.Add("Historico (log de eventos)")
[void]$cmbModoImp.Items.Add("Status atual (fila)")
$cmbModoImp.SelectedIndex = 0

$lblFiltroImp = New-Object System.Windows.Forms.Label
$lblFiltroImp.Text = "Buscar (impressora/porta):"
$lblFiltroImp.Location = New-Object System.Drawing.Point(270, 15)
$lblFiltroImp.Size = New-Object System.Drawing.Size(140, 20)

$txtBuscaImp = New-Object System.Windows.Forms.TextBox
$txtBuscaImp.Location = New-Object System.Drawing.Point(415, 13)
$txtBuscaImp.Size = New-Object System.Drawing.Size(180, 24)
$txtBuscaImp.Text = ""

$lblResumoImp = New-Object System.Windows.Forms.Label
$lblResumoImp.Location = New-Object System.Drawing.Point(605, 17)
$lblResumoImp.Size = New-Object System.Drawing.Size(685, 20)
$lblResumoImp.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblResumoImp.Anchor = "Top,Left,Right"

$gridImp = New-GridPadrao -X 10 -Y 50 -W 1280 -H 650

$tabImpressoras.Controls.Add($lblModoImp)
$tabImpressoras.Controls.Add($cmbModoImp)
$tabImpressoras.Controls.Add($lblFiltroImp)
$tabImpressoras.Controls.Add($txtBuscaImp)
$tabImpressoras.Controls.Add($lblResumoImp)
$tabImpressoras.Controls.Add($gridImp)

# ============================================================
#  ABA 4 - LOG DO SISTEMA (BITBAR)
# ============================================================
$tabLogSistema = New-Object System.Windows.Forms.TabPage
$tabLogSistema.Text = "Log do Sistema"
$tabLogSistema.BackColor = [System.Drawing.Color]::White

$btnAbrirPdf = New-Object System.Windows.Forms.Button
$btnAbrirPdf.Text = "Abrir PDF do Log"
$btnAbrirPdf.Location = New-Object System.Drawing.Point(10, 10)
$btnAbrirPdf.Size = New-Object System.Drawing.Size(130, 28)

$lblArquivo = New-Object System.Windows.Forms.Label
$lblArquivo.Text = "Nenhum arquivo carregado."
$lblArquivo.Location = New-Object System.Drawing.Point(150, 15)
$lblArquivo.Size = New-Object System.Drawing.Size(500, 20)
$lblArquivo.ForeColor = [System.Drawing.Color]::DimGray

$lblFiltroLog = New-Object System.Windows.Forms.Label
$lblFiltroLog.Text = "Filtrar sessao:"
$lblFiltroLog.Location = New-Object System.Drawing.Point(660, 15)
$lblFiltroLog.Size = New-Object System.Drawing.Size(90, 20)

$txtFiltroLog = New-Object System.Windows.Forms.TextBox
$txtFiltroLog.Location = New-Object System.Drawing.Point(755, 12)
$txtFiltroLog.Size = New-Object System.Drawing.Size(180, 24)
$txtFiltroLog.Text = ""

$gridSecoes = New-GridPadrao -X 10 -Y 50 -W 1280 -H 180
$gridSecoes.Anchor = "Top,Left,Right"

$gridRegistros = New-GridPadrao -X 10 -Y 245 -W 1280 -H 455

$lblRegistros = New-Object System.Windows.Forms.Label
$lblRegistros.Text = "Registros da sessao selecionada (duplo clique abre o JSON):"
$lblRegistros.Location = New-Object System.Drawing.Point(10, 225)
$lblRegistros.Size = New-Object System.Drawing.Size(500, 18)
$lblRegistros.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
$lblRegistros.ForeColor = [System.Drawing.Color]::DimGray

$tabLogSistema.Controls.Add($btnAbrirPdf)
$tabLogSistema.Controls.Add($lblArquivo)
$tabLogSistema.Controls.Add($lblFiltroLog)
$tabLogSistema.Controls.Add($txtFiltroLog)
$tabLogSistema.Controls.Add($gridSecoes)
$tabLogSistema.Controls.Add($lblRegistros)
$tabLogSistema.Controls.Add($gridRegistros)

# Adiciona abas
$tabs.Controls.Add($tabDesligamentos)
$tabs.Controls.Add($tabCredenciais)
$tabs.Controls.Add($tabImpressoras)
$tabs.Controls.Add($tabLogSistema)

# ============================================================
#  STATUS BAR
# ============================================================
$status = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "Pronto."
$status.Items.Add($statusLabel) | Out-Null

# ============================================================
#  ADICIONA AO FORM
# ============================================================
$form.Controls.Add($lblPeriodo)
$form.Controls.Add($numDias)
$form.Controls.Add($btnAtualizarTudo)
$form.Controls.Add($btnLimparAlertas)
$form.Controls.Add($lblIntervalo)
$form.Controls.Add($numIntervalo)
$form.Controls.Add($chkAuto)
$form.Controls.Add($tabs)
$form.Controls.Add($status)

# ============================================================
#  ESTADO
# ============================================================
$script:DadosDeslBrutos = @()
$script:DadosDeslFiltrados = @()
$script:DadosCredBrutos = @()
$script:DadosCredFiltrados = @()
$script:DadosImpBrutos = @()
$script:DadosImpFiltrados = @()
$script:LogRegistros = @()
$script:LogSecoes = @()
$script:SecaoSelecionada = ""
$script:UltimoErroPdf = ""

$script:Cores = @{
    41=[System.Drawing.Color]::LightCoral; 6008=[System.Drawing.Color]::Khaki
    1001=[System.Drawing.Color]::Plum; 1074=[System.Drawing.Color]::LightGreen
    4625=[System.Drawing.Color]::LightCoral; 4776=[System.Drawing.Color]::Khaki
    4740=[System.Drawing.Color]::Plum; 6161=[System.Drawing.Color]::LightCoral
    808=[System.Drawing.Color]::Khaki; 307=[System.Drawing.Color]::LightGreen
}

$script:TipoDesl = @{41="Kernel-Power";6008="Desligamento Inesperado";1001="BSOD";1074="Desligamento Planejado"}
$script:TipoCred = @{4625="Falha de Logon";4776="Validacao de Credenciais";4740="Conta Bloqueada"}
$script:TipoImp = @{307="Trabalho Enviado";6161="Falha de Comunicacao";808="Erro de Impressao"}

# ============================================================
#  HELPERS
# ============================================================
function Get-DadosDoEvento {
    param($Evento)
    $r = [PSCustomObject]@{
        Usuario="(desconhecido)"; Workstation=""; IpAddress=""
        LogonType=""; Status=""; SubStatus=""
    }
    try {
        $xml = [xml]$Evento.ToXml()
        if ($xml.Event.EventData -and $xml.Event.EventData.Data) {
            foreach ($n in @("TargetUserName","SubjectUserName","AccountName","User","UserName")) {
                $no = $xml.Event.EventData.Data | Where-Object { $_.Name -eq $n } | Select-Object -First 1
                if ($no -and $no.'#text' -and $no.'#text'.Trim() -ne '') { $r.Usuario = $no.'#text'.Trim(); break }
            }
            foreach ($n in @("WorkstationName","Workstation")) {
                $no = $xml.Event.EventData.Data | Where-Object { $_.Name -eq $n } | Select-Object -First 1
                if ($no -and $no.'#text') { $r.Workstation = $no.'#text'.Trim(); break }
            }
            foreach ($n in @("IpAddress","ClientAddress","SourceNetworkAddress")) {
                $no = $xml.Event.EventData.Data | Where-Object { $_.Name -eq $n } | Select-Object -First 1
                if ($no -and $no.'#text') { $r.IpAddress = $no.'#text'.Trim(); break }
            }
            $no = $xml.Event.EventData.Data | Where-Object { $_.Name -eq "LogonType" } | Select-Object -First 1
            if ($no -and $no.'#text') { $r.LogonType = $no.'#text'.Trim() }
            $no = $xml.Event.EventData.Data | Where-Object { $_.Name -eq "Status" } | Select-Object -First 1
            if ($no -and $no.'#text') { $r.Status = $no.'#text'.Trim() }
            $no = $xml.Event.EventData.Data | Where-Object { $_.Name -eq "SubStatus" } | Select-Object -First 1
            if ($no -and $no.'#text') { $r.SubStatus = $no.'#text'.Trim() }
        }
    } catch { }
    if ($r.Usuario -eq "(desconhecido)" -and $Evento.UserId) {
        try {
            $sid = New-Object System.Security.Principal.SecurityIdentifier($Evento.UserId.Value)
            $r.Usuario = $sid.Translate([System.Security.Principal.NTAccount]).Value
        } catch { $r.Usuario = $Evento.UserId.Value }
    }
    return $r
}

function Get-CampoEventoImpressora {
    param($Xml, [string[]]$Nomes)
    foreach ($nome in $Nomes) {
        $no = $Xml.Event.EventData.Data | Where-Object { $_.Name -eq $nome } | Select-Object -First 1
        if ($no -and $no.'#text' -and $no.'#text'.Trim() -ne '') { return $no.'#text'.Trim() }
    }
    return ""
}

# ============================================================
#  CARREGADORES
# ============================================================
function Carregar-Desligamentos {
    $statusLabel.Text = "Consultando eventos de desligamento..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $form.Refresh()
    try {
        $dias = [int]$numDias.Value
        $dataCorte = if ($dias -gt 0) { (Get-Date).AddDays(-$dias) } else { $null }
        $filtro = @{ LogName = 'System'; Id = 41, 6008, 1001, 1074 }
        if ($dataCorte) { $filtro.StartTime = $dataCorte }
        $eventos = Get-WinEvent -FilterHashtable $filtro -ErrorAction Stop
        $lista = foreach ($ev in $eventos) {
            [PSCustomObject]@{
                DataHora=$ev.TimeCreated; EventoID=$ev.Id; Tipo=$script:TipoDesl[$ev.Id]
                Fonte=$ev.ProviderName; Usuario=$ev.UserId
                Mensagem=($ev.Message -replace "`r"," " -replace "`n"," ")
                MensagemCompleta=$ev.Message
            }
        }
        $script:DadosDeslBrutos = @($lista | Sort-Object DataHora -Descending)
        Aplicar-FiltroDesl
        $statusLabel.Text = "Desligamentos: $($script:DadosDeslBrutos.Count) eventos."
    } catch {
        if ($_.Exception.Message -match "No events were found") {
            $script:DadosDeslBrutos = @(); Aplicar-FiltroDesl
            $statusLabel.Text = "Nenhum evento de desligamento no periodo."
        } else { $statusLabel.Text = "Erro: $($_.Exception.Message)" }
    } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Aplicar-FiltroDesl {
    $fid = $null
    if ($cmbFiltroDesl.SelectedIndex -gt 0) { $fid = [int]($cmbFiltroDesl.SelectedItem -split ' ')[0] }
    $dados = if ($null -eq $fid) { $script:DadosDeslBrutos } else { $script:DadosDeslBrutos | Where-Object { $_.EventoID -eq $fid } }
    $script:DadosDeslFiltrados = @($dados)
    $gridDesl.DataSource = $null
    if ($script:DadosDeslFiltrados.Count -gt 0) {
        $bl = New-Object System.ComponentModel.BindingList[object]
        foreach ($i in $script:DadosDeslFiltrados) { $bl.Add($i) | Out-Null }
        $gridDesl.DataSource = $bl
        if ($gridDesl.Columns.Count -gt 0) {
            $gridDesl.Columns["DataHora"].DefaultCellStyle.Format = "dd/MM/yyyy HH:mm:ss"
            if ($gridDesl.Columns.Contains("MensagemCompleta")) { $gridDesl.Columns["MensagemCompleta"].Visible = $false }
        }
    }
    $q41=@($script:DadosDeslFiltrados|Where-Object{$_.EventoID -eq 41}).Count
    $q6008=@($script:DadosDeslFiltrados|Where-Object{$_.EventoID -eq 6008}).Count
    $q1001=@($script:DadosDeslFiltrados|Where-Object{$_.EventoID -eq 1001}).Count
    $q1074=@($script:DadosDeslFiltrados|Where-Object{$_.EventoID -eq 1074}).Count
    $lblResumoDesl.Text = "Kernel-Power: $q41 | 6008: $q6008 | BSOD: $q1001 | Planejados: $q1074 | Total: $($script:DadosDeslFiltrados.Count)"
}

function Carregar-Credenciais {
    $statusLabel.Text = "Consultando eventos de credenciais..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $form.Refresh()
    try {
        $dias = [int]$numDias.Value
        $dataCorte = if ($dias -gt 0) { (Get-Date).AddDays(-$dias) } else { $null }
        $filtro = @{ LogName = 'Security'; Id = 4625, 4776, 4740 }
        if ($dataCorte) { $filtro.StartTime = $dataCorte }
        $eventos = Get-WinEvent -FilterHashtable $filtro -MaxEvents 5000 -ErrorAction Stop
        $usuariosAlvo = @()
        if ($txtUsuarioCred.Text.Trim() -ne '') {
            $usuariosAlvo = $txtUsuarioCred.Text.Split(';') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
        }
        $lista = foreach ($ev in $eventos) {
            $info = Get-DadosDoEvento -Evento $ev
            if ($usuariosAlvo.Count -gt 0) {
                $bateu = $false
                foreach ($u in $usuariosAlvo) { if ($info.Usuario -like "*$u*") { $bateu = $true; break } }
                if (-not $bateu) { continue }
            }
            $st = ""
            if ($info.Status -or $info.SubStatus) {
                $cod = if ($info.SubStatus) { $info.SubStatus } else { $info.Status }
                $st = "$cod ($(Get-StatusDescricao -Codigo $cod))"
            }
            [PSCustomObject]@{
                DataHora=$ev.TimeCreated; EventoID=$ev.Id; Tipo=$script:TipoCred[$ev.Id]
                Usuario=$info.Usuario; Workstation=$info.Workstation; IP=$info.IpAddress
                LogonType=$info.LogonType; Status=$st; Fonte=$ev.ProviderName
                Mensagem=($ev.Message -replace "`r"," " -replace "`n"," ")
                MensagemCompleta=$ev.Message
            }
        }
        $script:DadosCredBrutos = @($lista | Sort-Object DataHora -Descending)
        Aplicar-FiltroCred
        $statusLabel.Text = "Credenciais: $($script:DadosCredBrutos.Count) eventos."
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match "No events were found") {
            $script:DadosCredBrutos = @(); Aplicar-FiltroCred
            $statusLabel.Text = "Nenhum evento de credencial."
        } elseif ($msg -match "unauthorized|Acesso negado|Access is denied") {
            [System.Windows.Forms.MessageBox]::Show("Rode como Administrador para ler o log Security.","Permissao","OK","Warning") | Out-Null
        } else { $statusLabel.Text = "Erro: $msg" }
    } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
}

function Aplicar-FiltroCred {
    $fid = $null
    if ($cmbFiltroCred.SelectedIndex -gt 0) { $fid = [int]($cmbFiltroCred.SelectedItem -split ' ')[0] }
    $busca = $txtBuscaCred.Text.Trim()
    $dados = $script:DadosCredBrutos
    if ($null -ne $fid) { $dados = $dados | Where-Object { $_.EventoID -eq $fid } }
    if ($busca -ne '') {
        $dados = $dados | Where-Object {
            $_.IP -like "*$busca*" -or $_.Workstation -like "*$busca*" -or $_.Usuario -like "*$busca*"
        }
    }
    $script:DadosCredFiltrados = @($dados)
    $gridCred.DataSource = $null
    if ($script:DadosCredFiltrados.Count -gt 0) {
        $bl = New-Object System.ComponentModel.BindingList[object]
        foreach ($i in $script:DadosCredFiltrados) { $bl.Add($i) | Out-Null }
        $gridCred.DataSource = $bl
        if ($gridCred.Columns.Count -gt 0) {
            $gridCred.Columns["DataHora"].DefaultCellStyle.Format = "dd/MM/yyyy HH:mm:ss"
            if ($gridCred.Columns.Contains("MensagemCompleta")) { $gridCred.Columns["MensagemCompleta"].Visible = $false }
        }
    }
    $q4625=@($script:DadosCredFiltrados|Where-Object{$_.EventoID -eq 4625}).Count
    $q4776=@($script:DadosCredFiltrados|Where-Object{$_.EventoID -eq 4776}).Count
    $q4740=@($script:DadosCredFiltrados|Where-Object{$_.EventoID -eq 4740}).Count
    $lblResumoCred.Text = "Falhas: $q4625 | NTLM: $q4776 | Bloqueadas: $q4740 | Total: $($script:DadosCredFiltrados.Count)"
}

function Carregar-Impressoras {
    $statusLabel.Text = "Consultando impressoras..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $form.Refresh()
    if ($cmbModoImp.SelectedIndex -eq 0) {
        try {
            $log = Get-WinEvent -ListLog "Microsoft-Windows-PrintService/Operational" -ErrorAction Stop
            if (-not $log.IsEnabled) { $log.IsEnabled = $true; try { $log.SaveChanges() } catch { } }
            $dias = [int]$numDias.Value
            $dataCorte = if ($dias -gt 0) { (Get-Date).AddDays(-$dias) } else { $null }
            $filtro = @{ LogName='Microsoft-Windows-PrintService/Operational'; Id=307,6161,808 }
            if ($dataCorte) { $filtro.StartTime = $dataCorte }
            $eventos = Get-WinEvent -FilterHashtable $filtro -MaxEvents 5000 -ErrorAction Stop
            $lista = foreach ($ev in $eventos) {
                $xml=$null; try { $xml=[xml]$ev.ToXml() } catch {}
                $imp="";$prt="";$doc="";$usr="";$tam=""
                if ($xml) {
                    $imp=Get-CampoEventoImpressora -Xml $xml -Nomes @("Param3","PrinterName","Name")
                    $prt=Get-CampoEventoImpressora -Xml $xml -Nomes @("Param4","PortName","Port")
                    $doc=Get-CampoEventoImpressora -Xml $xml -Nomes @("Param2","DocumentName","Document")
                    $usr=Get-CampoEventoImpressora -Xml $xml -Nomes @("Param1","UserName","User")
                    $tam=Get-CampoEventoImpressora -Xml $xml -Nomes @("Param5","Size","Bytes")
                }
                [PSCustomObject]@{
                    DataHora=$ev.TimeCreated; EventoID=$ev.Id; Tipo=$script:TipoImp[$ev.Id]
                    Impressora=$imp; Porta=$prt; Documento=$doc; Usuario=$usr; Tamanho=$tam
                    Fonte=$ev.ProviderName; Mensagem=($ev.Message -replace "`r"," " -replace "`n"," ")
                    MensagemCompleta=$ev.Message
                }
            }
            $script:DadosImpBrutos = @($lista | Sort-Object DataHora -Descending)
        } catch {
            $msg = $_.Exception.Message
            if ($msg -match "No events were found") {
                $script:DadosImpBrutos=@(); $statusLabel.Text = "Nenhum evento."
            } elseif ($msg -match "unauthorized|Acesso negado") {
                $script:DadosImpBrutos=@()
                [System.Windows.Forms.MessageBox]::Show("Rode como Admin para o log PrintService.","Permissao","OK","Warning") | Out-Null
            } else { $script:DadosImpBrutos=@(); $statusLabel.Text = "Erro: $msg" }
        }
    } else {
        try {
            $impressoras = Get-Printer -ErrorAction Stop
            $lista = foreach ($imp in $impressoras) {
                $jobs=@(); try { $jobs=@(Get-PrintJob -PrinterName $imp.Name -ErrorAction SilentlyContinue) } catch {}
                [PSCustomObject]@{
                    Nome=$imp.Name; Status="$($imp.PrinterStatus)"; Porta=$imp.PortName
                    Driver=$imp.DriverName; Compartilhada=if($imp.Shared){"Sim"}else{"Nao"}
                    JobsAtivos=$jobs.Count; JobsComErro=@($jobs|Where-Object{$_.JobStatus -ne "Normal"}).Count
                    Local=if($imp.Shared){"\\$env:COMPUTERNAME\$($imp.ShareName)"}else{"(local)"}
                }
            }
            $script:DadosImpBrutos = @($lista | Sort-Object Nome)
        } catch { $script:DadosImpBrutos=@(); $statusLabel.Text = "Erro: $($_.Exception.Message)" }
    }
    Aplicar-FiltroImp
    $statusLabel.Text = "Impressoras: $($script:DadosImpBrutos.Count) registros."
    $form.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Aplicar-FiltroImp {
    $busca = $txtBuscaImp.Text.Trim()
    $dados = $script:DadosImpBrutos
    if ($busca -ne '') {
        if ($cmbModoImp.SelectedIndex -eq 0) {
            $dados = $dados | Where-Object { $_.Impressora -like "*$busca*" -or $_.Porta -like "*$busca*" -or $_.Usuario -like "*$busca*" -or $_.Documento -like "*$busca*" }
        } else {
            $dados = $dados | Where-Object { $_.Nome -like "*$busca*" -or $_.Porta -like "*$busca*" }
        }
    }
    $script:DadosImpFiltrados = @($dados)
    $gridImp.DataSource = $null
    if ($script:DadosImpFiltrados.Count -gt 0) {
        $bl = New-Object System.ComponentModel.BindingList[object]
        foreach ($i in $script:DadosImpFiltrados) { $bl.Add($i) | Out-Null }
        $gridImp.DataSource = $bl
        if ($gridImp.Columns.Count -gt 0) {
            if ($cmbModoImp.SelectedIndex -eq 0) {
                $gridImp.Columns["DataHora"].DefaultCellStyle.Format = "dd/MM/yyyy HH:mm:ss"
                if ($gridImp.Columns.Contains("Mensagem")) { $gridImp.Columns["Mensagem"].Visible = $false }
                if ($gridImp.Columns.Contains("MensagemCompleta")) { $gridImp.Columns["MensagemCompleta"].Visible = $false }
            }
        }
    }
    if ($cmbModoImp.SelectedIndex -eq 0) {
        $qF=@($script:DadosImpFiltrados|Where-Object{$_.EventoID -eq 6161}).Count
        $qE=@($script:DadosImpFiltrados|Where-Object{$_.EventoID -eq 808}).Count
        $qO=@($script:DadosImpFiltrados|Where-Object{$_.EventoID -eq 307}).Count
        $lblResumoImp.Text = "Falhas: $qF | Erros: $qE | OK: $qO | Total: $($script:DadosImpFiltrados.Count)"
    } else {
        $qOff=@($script:DadosImpFiltrados|Where-Object{$_.Status -ne "Normal"}).Count
        $qErr=@($script:DadosImpFiltrados|Where-Object{$_.JobsComErro -gt 0}).Count
        $lblResumoImp.Text = "Impressoras: $($script:DadosImpFiltrados.Count) | Nao-Normais: $qOff | Com Erro: $qErr"
    }
}

# ============================================================
#  LOG DO SISTEMA - FUNCOES
# ============================================================
function Agrupar-Sessoes {
    $grupos = @{}
    foreach ($r in $script:LogRegistros) {
        if (-not $grupos.ContainsKey($r.Secao)) {
            $grupos[$r.Secao] = New-Object System.Collections.ArrayList
        }
        [void]$grupos[$r.Secao].Add($r)
    }

    $lista = New-Object System.Collections.ArrayList
    foreach ($nome in $grupos.Keys) {
        $regs = $grupos[$nome]
        $horas = $regs | ForEach-Object { $_.Hora } | Sort-Object
        [void]$lista.Add([PSCustomObject]@{
            Secao       = $nome
            Qtd         = $regs.Count
            HoraInicial = $horas | Select-Object -First 1
            HoraFinal   = $horas | Select-Object -Last 1
        })
    }
    return @($lista | Sort-Object Secao)
}

function Atualizar-GridSecoes {
    $secoes = Agrupar-Sessoes
    $filtro = $txtFiltroLog.Text.Trim()
    if ($filtro -ne '') {
        $secoes = $secoes | Where-Object { $_.Secao -like "*$filtro*" }
    }
    $script:LogSecoes = @($secoes)

    $gridSecoes.DataSource = $null
    if ($script:LogSecoes.Count -gt 0) {
        $bl = New-Object System.ComponentModel.BindingList[object]
        foreach ($i in $script:LogSecoes) { $bl.Add($i) | Out-Null }
        $gridSecoes.DataSource = $bl

        if ($gridSecoes.Columns.Count -gt 0) {
            $gridSecoes.Columns["Secao"].FillWeight = 50
            $gridSecoes.Columns["Qtd"].FillWeight = 10
            $gridSecoes.Columns["Qtd"].DefaultCellStyle.Alignment = "MiddleCenter"
            $gridSecoes.Columns["HoraInicial"].FillWeight = 20
            $gridSecoes.Columns["HoraFinal"].FillWeight = 20
        }
    }
    $gridRegistros.DataSource = $null
    $script:SecaoSelecionada = ""
}

function Atualizar-GridRegistros {
    param([string]$Secao)
    $script:SecaoSelecionada = $Secao
    $dados = $script:LogRegistros | Where-Object { $_.Secao -eq $Secao }

    $gridRegistros.DataSource = $null
    if (@($dados).Count -gt 0) {
        $bl = New-Object System.ComponentModel.BindingList[object]
        foreach ($i in $dados) { $bl.Add($i) | Out-Null }
        $gridRegistros.DataSource = $bl

        if ($gridRegistros.Columns.Count -gt 0) {
            $gridRegistros.Columns["Secao"].Visible = $false
            $gridRegistros.Columns["Data"].Visible = $false
            $gridRegistros.Columns["Hora"].FillWeight = 12
            $gridRegistros.Columns["Usuario"].FillWeight = 12
            $gridRegistros.Columns["Computador"].FillWeight = 12
            $gridRegistros.Columns["Tipo"].FillWeight = 15
            $gridRegistros.Columns["Descricao"].FillWeight = 49
            if ($gridRegistros.Columns.Contains("Payload")) {
                $gridRegistros.Columns["Payload"].Visible = $false
            }
        }
    }
    $statusLabel.Text = "Sessao '$Secao': $(@($dados).Count) registros."
}

# ============================================================
#  COLORACAO DOS GRIDS
# ============================================================
$gridDesl.add_CellFormatting({
    param($s,$e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $r = $gridDesl.Rows[$e.RowIndex]
    if ($r.Cells.Count -le 1) { return }
    $id = $r.Cells[1].Value
    if ($null -eq $id) { return }
    $id = [int]$id
    if ($script:Cores.ContainsKey($id)) {
        $e.CellStyle.BackColor = $script:Cores[$id]
        $e.CellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(
            [Math]::Max(0,$script:Cores[$id].R-40),
            [Math]::Max(0,$script:Cores[$id].G-40),
            [Math]::Max(0,$script:Cores[$id].B-40))
    }
})

$gridCred.add_CellFormatting({
    param($s,$e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $r = $gridCred.Rows[$e.RowIndex]
    if ($r.Cells.Count -le 1) { return }
    $id = $r.Cells[1].Value
    if ($null -eq $id) { return }
    $id = [int]$id
    if ($script:Cores.ContainsKey($id)) {
        $e.CellStyle.BackColor = $script:Cores[$id]
        $e.CellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(
            [Math]::Max(0,$script:Cores[$id].R-40),
            [Math]::Max(0,$script:Cores[$id].G-40),
            [Math]::Max(0,$script:Cores[$id].B-40))
    }
})

$gridImp.add_CellFormatting({
    param($s,$e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $r = $gridImp.Rows[$e.RowIndex]
    if ($r.Cells.Count -le 1) { return }
    if ($cmbModoImp.SelectedIndex -eq 0) {
        $id = $r.Cells[1].Value
        if ($null -eq $id) { return }
        $id = [int]$id
        if ($script:Cores.ContainsKey($id)) {
            $e.CellStyle.BackColor = $script:Cores[$id]
            $e.CellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(
                [Math]::Max(0,$script:Cores[$id].R-40),
                [Math]::Max(0,$script:Cores[$id].G-40),
                [Math]::Max(0,$script:Cores[$id].B-40))
        }
    } else {
        $st = $r.Cells["Status"].Value
        $er = $r.Cells["JobsComErro"].Value
        if ($er -and [int]$er -gt 0) { $e.CellStyle.BackColor = [System.Drawing.Color]::LightCoral }
        elseif ($st -and $st -ne "Normal") { $e.CellStyle.BackColor = [System.Drawing.Color]::Khaki }
        else { $e.CellStyle.BackColor = [System.Drawing.Color]::LightGreen }
    }
})

$gridRegistros.add_CellFormatting({
    param($s,$e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $r = $gridRegistros.Rows[$e.RowIndex]
    if ($r.Cells.Count -eq 0) { return }
    $desc = $r.Cells["Descricao"].Value
    if ($desc) {
        $descStr = "$desc"
        if ($descStr -match '"sucesso"\s*:\s*false' -or $descStr -match '"codigo_erro"\s*:\s*[1-9]' -or $descStr -match 'bloqueado' -or $descStr -match 'não existe') {
            $e.CellStyle.BackColor = [System.Drawing.Color]::LightCoral
            $e.CellStyle.ForeColor = [System.Drawing.Color]::DarkRed
        }
        elseif ($descStr -match '"sucesso"\s*:\s*true') {
            $e.CellStyle.BackColor = [System.Drawing.Color]::Honeydew
        }
    }
})

# ============================================================
#  EVENTOS DOS CONTROLES
# ============================================================
$btnAtualizarTudo.Add_Click({
    switch ($tabs.SelectedIndex) {
        0 { Carregar-Desligamentos }
        1 { Carregar-Credenciais }
        2 { Carregar-Impressoras }
        3 { }
    }
})

$btnLimparAlertas.Add_Click({
    $resp = [System.Windows.Forms.MessageBox]::Show(
        "Remover o destaque vermelho dos alertas atuais?","Limpar Alertas","YesNo","Question")
    if ($resp -ne "Yes") { return }
    $gridCred.Refresh()
    $statusLabel.Text = "Alertas limpos."
})

$cmbFiltroDesl.Add_SelectedIndexChanged({ Aplicar-FiltroDesl })
$cmbFiltroCred.Add_SelectedIndexChanged({ Aplicar-FiltroCred })
$cmbModoImp.Add_SelectedIndexChanged({ Carregar-Impressoras })

$txtUsuarioCred.Add_KeyDown({
    param($s,$e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $script:Config.UsuariosCred = $txtUsuarioCred.Text
        Salvar-Config -Config $script:Config
        Carregar-Credenciais
        $e.SuppressKeyPress = $true
    }
})
$txtBuscaCred.Add_TextChanged({ Aplicar-FiltroCred })
$txtBuscaImp.Add_TextChanged({ Aplicar-FiltroImp })

$numDias.Add_ValueChanged({
    $script:Config.Dias = [int]$numDias.Value
    Salvar-Config -Config $script:Config
    $statusLabel.Text = "Periodo alterado. Clique em Atualizar."
})

$numIntervalo.Add_ValueChanged({
    $script:Config.IntervaloMin = [int]$numIntervalo.Value
    Salvar-Config -Config $script:Config
    $timer.Interval = [int]$numIntervalo.Value * 60 * 1000
})

$chkAuto.Add_CheckedChanged({
    $script:Config.AlertaAtivo = $chkAuto.Checked
    Salvar-Config -Config $script:Config
    if ($chkAuto.Checked) { $timer.Start(); $statusLabel.Text = "Auto-atualizacao ativada." }
    else { $timer.Stop(); $statusLabel.Text = "Auto-atualizacao desativada." }
})

# --- Abrir PDF ---
$btnAbrirPdf.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = "Arquivos PDF (*.pdf)|*.pdf|Todos os arquivos (*.*)|*.*"
    $dlg.Title = "Selecione o log do sistema (PDF)"
    if ($script:Config.UltimoPdf -and (Test-Path (Split-Path $script:Config.UltimoPdf -Parent))) {
        $dlg.InitialDirectory = Split-Path $script:Config.UltimoPdf -Parent
    }
    if ($dlg.ShowDialog() -ne "OK") { return }

    $caminho = $dlg.FileName
    $lblArquivo.Text = $caminho
    $script:Config.UltimoPdf = $caminho
    Salvar-Config -Config $script:Config

    $statusLabel.Text = "Verificando dependencia (PdfPig)..."
    $form.Refresh()

    $dll = Garantir-PdfPig
    if (-not $dll) { return }

    $statusLabel.Text = "Extraindo texto do PDF..."
    $form.Refresh()

    $script:UltimoErroPdf = ""
    $texto = Extrair-TextoPdfPig -CaminhoPdf $caminho

    if (-not $texto) {
        $detalhe = if ($script:UltimoErroPdf) { $script:UltimoErroPdf } else { "(sem detalhes)" }
        [System.Windows.Forms.MessageBox]::Show(
            "Falha ao extrair texto do PDF.`r`n`r`nDetalhes tecnicos:`r`n$detalhe",
            "Erro leitura","OK","Error") | Out-Null
        return
    }

    # ============================================================
    #  DIAGNOSTICO - mostra o texto bruto extraido
    # ============================================================
    $script:TextoBrutoPdf = $texto
    $linhasBrutas = ($texto -split "`r?`n") | Where-Object { $_.Trim() -ne "" }
    $totalLinhas = @($linhasBrutas).Count

    # Preview: primeiras 40 linhas nao vazias
    $preview = ($linhasBrutas | Select-Object -First 40) -join "`r`n"
    $msgDiag = @"
Texto extraido: $($texto.Length) caracteres
Linhas nao vazias: $totalLinhas

============================================================
PREVIEW DAS PRIMEIRAS 40 LINHAS NAO VAZIAS:
============================================================

$preview
"@

    # Popup de diagnostico com botao para copiar tudo
    $diagForm = New-Object System.Windows.Forms.Form
    $diagForm.Text = "Diagnostico - Texto extraido do PDF"
    $diagForm.Size = New-Object System.Drawing.Size(1000, 700)
    $diagForm.StartPosition = "CenterParent"

    $txtDiag = New-Object System.Windows.Forms.TextBox
    $txtDiag.Multiline = $true
    $txtDiag.ReadOnly = $true
    $txtDiag.ScrollBars = "Both"
    $txtDiag.WordWrap = $false
    $txtDiag.Dock = "Fill"
    $txtDiag.Font = New-Object System.Drawing.Font("Consolas", 9)
    $txtDiag.Text = $msgDiag
    $txtDiag.Select(0, 0)

    $panelBotoes = New-Object System.Windows.Forms.Panel
    $panelBotoes.Dock = "Bottom"
    $panelBotoes.Height = 45

    $btnCopiarTudo = New-Object System.Windows.Forms.Button
    $btnCopiarTudo.Text = "Copiar Texto Completo"
    $btnCopiarTudo.Location = New-Object System.Drawing.Point(10, 8)
    $btnCopiarTudo.Size = New-Object System.Drawing.Size(160, 30)
    $btnCopiarTudo.Add_Click({
        [System.Windows.Forms.Clipboard]::SetText($script:TextoBrutoPdf)
        [System.Windows.Forms.MessageBox]::Show("Texto completo copiado para a area de transferencia.`r`n`r`nCole aqui no chat para eu ajustar o parser.","Copiado") | Out-Null
    })

    $btnCopiarPreview = New-Object System.Windows.Forms.Button
    $btnCopiarPreview.Text = "Copiar Preview"
    $btnCopiarPreview.Location = New-Object System.Drawing.Point(180, 8)
    $btnCopiarPreview.Size = New-Object System.Drawing.Size(130, 30)
    $btnCopiarPreview.Add_Click({
        [System.Windows.Forms.Clipboard]::SetText($msgDiag)
        [System.Windows.Forms.MessageBox]::Show("Preview copiado.","Copiado") | Out-Null
    })

    $btnFecharDiag = New-Object System.Windows.Forms.Button
    $btnFecharDiag.Text = "Fechar e parsear"
    $btnFecharDiag.Location = New-Object System.Drawing.Point(320, 8)
    $btnFecharDiag.Size = New-Object System.Drawing.Size(140, 30)
    $btnFecharDiag.Add_Click({ $diagForm.Close() })

    $panelBotoes.Controls.Add($btnCopiarTudo)
    $panelBotoes.Controls.Add($btnCopiarPreview)
    $panelBotoes.Controls.Add($btnFecharDiag)

    $diagForm.Controls.Add($txtDiag)
    $diagForm.Controls.Add($panelBotoes)

    [void]$diagForm.ShowDialog()
    $diagForm.Dispose()

    # ============================================================
    #  Segue com o parser normal
    # ============================================================
    $statusLabel.Text = "Parseando registros..."
    $form.Refresh()

    $script:LogRegistros = Parse-LogBitBar -TextoCompleto $texto
    Atualizar-GridSecoes

    if ($script:LogRegistros.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Texto foi extraido ($($texto.Length) caracteres), mas nenhum registro foi reconhecido.`r`n`r`nUse o botao 'Copiar Texto Completo' no diagnostico e cole aqui no chat para eu ajustar o parser.",
            "Parser nao reconheceu","OK","Warning") | Out-Null
    }

    $statusLabel.Text = "Log carregado: $($script:LogRegistros.Count) registros em $(@($script:LogSecoes).Count) sessoes."
})

$txtFiltroLog.Add_TextChanged({ Atualizar-GridSecoes })

$gridSecoes.Add_CellDoubleClick({
    if ($gridSecoes.SelectedRows.Count -eq 0) { return }
    $row = $gridSecoes.SelectedRows[0]
    $secao = "$($row.Cells['Secao'].Value)"
    if ($secao) { Atualizar-GridRegistros -Secao $secao }
})

$gridRegistros.Add_CellDoubleClick({
    if ($gridRegistros.SelectedRows.Count -eq 0) { return }
    $row = $gridRegistros.SelectedRows[0]

    $secao = "$($row.Cells['Secao'].Value)"
    $dataHora = "$($row.Cells['DataHora'].Value)"
    $usuario = "$($row.Cells['Usuario'].Value)"
    $computador = "$($row.Cells['Computador'].Value)"
    $tipo = "$($row.Cells['Tipo'].Value)"
    $descricao = "$($row.Cells['Descricao'].Value)"

    $payloadObj = $null
    $jsonMatch = [regex]::Match($descricao, '\{.*\}')
    if ($jsonMatch.Success) {
        try { $payloadObj = $jsonMatch.Value | ConvertFrom-Json } catch { $payloadObj = $null }
    }

    $obj = [ordered]@{
        Secao      = $secao
        DataHora   = $dataHora
        Usuario    = $usuario
        Computador = $computador
        Tipo       = $tipo
        Descricao  = $descricao
    }
    if ($payloadObj) { $obj["Payload"] = $payloadObj }

    $jsonFinal = $obj | ConvertTo-Json -Depth 10

    Show-DetalhesJson -Titulo "Detalhes - $secao" -JsonText $jsonFinal
})

$gridDesl.Add_CellDoubleClick({
    if ($gridDesl.SelectedRows.Count -eq 0) { return }
    $r = $gridDesl.SelectedRows[0]
    $msg = "$($r.Cells['MensagemCompleta'].Value)"
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = "$($r.Cells['Mensagem'].Value)" }
    [System.Windows.Forms.MessageBox]::Show($msg,"Detalhes") | Out-Null
})
$gridCred.Add_CellDoubleClick({
    if ($gridCred.SelectedRows.Count -eq 0) { return }
    $r = $gridCred.SelectedRows[0]
    $msg = "$($r.Cells['MensagemCompleta'].Value)"
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = "$($r.Cells['Mensagem'].Value)" }
    [System.Windows.Forms.MessageBox]::Show($msg,"Detalhes") | Out-Null
})
$gridImp.Add_CellDoubleClick({
    if ($gridImp.SelectedRows.Count -eq 0) { return }
    $r = $gridImp.SelectedRows[0]
    $msg = "$($r.Cells['MensagemCompleta'].Value)"
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = "$($r.Cells['Mensagem'].Value)" }
    [System.Windows.Forms.MessageBox]::Show($msg,"Detalhes") | Out-Null
})

# ============================================================
#  TIMER
# ============================================================
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [int]$numIntervalo.Value * 60 * 1000
$timer.Add_Tick({
    switch ($tabs.SelectedIndex) {
        0 { Carregar-Desligamentos }
        1 { Carregar-Credenciais }
        2 { Carregar-Impressoras }
    }
})

if ($chkAuto.Checked) { $timer.Start() }

# ============================================================
#  FECHAMENTO
# ============================================================
$form.Add_FormClosing({
    $timer.Stop()
})

# ============================================================
#  INICIALIZACAO
# ============================================================
$form.Add_Shown({
    Carregar-Desligamentos
})

[void]$form.ShowDialog()
$form.Dispose()