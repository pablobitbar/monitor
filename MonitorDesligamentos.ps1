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
    if ($script:StatusDesc.ContainsKey($cod)) {
        return $script:StatusDesc[$cod]
    }
    return "Codigo desconhecido"
}

# ============================================================
#  CONFIGURACAO PERSISTENTE
# ============================================================
# Quando rodado via "irm | iex", $PSScriptRoot fica vazio.
# Nesse caso, usamos uma pasta fixa em %LOCALAPPDATA%.
$script:BaseDir = if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Join-Path $env:LOCALAPPDATA "MonitorDesligamentos"
} else {
    $PSScriptRoot
}

if (-not (Test-Path $script:BaseDir)) {
    try {
        New-Item -ItemType Directory -Path $script:BaseDir -Force | Out-Null
    } catch {
        $script:BaseDir = $env:TEMP
    }
}

$script:ConfigPath = Join-Path $script:BaseDir "MonitorConfig.json"

function Carregar-Config {
    $default = [PSCustomObject]@{
        Dias          = 30
        UsuariosCred  = "bituser;bitbar"
        IntervaloMin  = 5
        AlertaAtivo   = $true
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
    try {
        $Config | ConvertTo-Json | Set-Content -Path $script:ConfigPath -Encoding UTF8
    } catch { }
}

$script:Config = Carregar-Config

# ============================================================
#  LOG DE IMPRESSORAS: HABILITAR SE PRECISO
# ============================================================
function Habilitar-LogImpressoras {
    try {
        $log = Get-WinEvent -ListLog "Microsoft-Windows-PrintService/Operational" -ErrorAction Stop
        if (-not $log.IsEnabled) {
            $log.IsEnabled = $true
            try { $log.SaveChanges() } catch { }
        }
        return $true
    }
    catch {
        return $false
    }
}

# ============================================================
#  FUNCAO: CRIAR DATAGRIDVIEW PADRAO (responsivo + scroll)
# ============================================================
function New-GridPadrao {
    param(
        [int]$X, [int]$Y, [int]$W, [int]$H
    )

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

    # Ativa DoubleBuffered via reflection (evita flicker e deixa mais suave)
    try {
        $prop = [System.Windows.Forms.DataGridView].GetProperty(
            "DoubleBuffered",
            [System.Reflection.BindingFlags]::NonPublic -bor [System.Reflection.BindingFlags]::Instance
        )
        $prop.SetValue($g, $true, $null)
    } catch { }

    return $g
}

# ============================================================
#  FUNCAO: MOSTRAR DETALHES FORMATADOS (popup bonito)
# ============================================================
function Show-DetalhesEvento {
    param(
        [string]$Titulo,
        [hashtable]$Campos,
        [string]$MensagemCompleta
    )

    $sb = New-Object System.Text.StringBuilder

    [void]$sb.AppendLine("========================================================")
    [void]$sb.AppendLine(" DETALHES DO EVENTO")
    [void]$sb.AppendLine("========================================================")
    [void]$sb.AppendLine()

    foreach ($chave in $Campos.Keys) {
        $valor = $Campos[$chave]
        [void]$sb.AppendLine((" {0,-13}: {1}" -f $chave, $valor))
    }

    [void]$sb.AppendLine()
    [void]$sb.AppendLine("========================================================")
    [void]$sb.AppendLine(" MENSAGEM COMPLETA")
    [void]$sb.AppendLine("========================================================")
    [void]$sb.AppendLine()

    if ([string]::IsNullOrWhiteSpace($MensagemCompleta)) {
        [void]$sb.AppendLine("(sem mensagem registrada)")
    }
    else {
        $linhas = $MensagemCompleta -split "`r?`n"
        $linhasLimpas = $linhas |
            ForEach-Object { $_.TrimEnd() } |
            Where-Object { $_.Trim() -ne '' }
        foreach ($l in $linhasLimpas) {
            [void]$sb.AppendLine($l)
        }
    }

    $popup = New-Object System.Windows.Forms.Form
    $popup.Text = "Detalhes do Evento"
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
    $txt.Text = $sb.ToString()
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
$form.Size = New-Object System.Drawing.Size(1350, 800)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(1100, 620)

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
$tabs.Size = New-Object System.Drawing.Size(1315, 690)
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

$gridDesl = New-GridPadrao -X 10 -Y 50 -W 1280 -H 600

$tabDesligamentos.Controls.Add($lblFiltroDesl)
$tabDesligamentos.Controls.Add($cmbFiltroDesl)
$tabDesligamentos.Controls.Add($lblResumoDesl)
$tabDesligamentos.Controls.Add($gridDesl)

# ============================================================
#  ABA 2 - CREDENCIAIS DE REDE
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

$gridCred = New-GridPadrao -X 10 -Y 50 -W 1280 -H 600

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

$gridImp = New-GridPadrao -X 10 -Y 50 -W 1280 -H 600

$tabImpressoras.Controls.Add($lblModoImp)
$tabImpressoras.Controls.Add($cmbModoImp)
$tabImpressoras.Controls.Add($lblFiltroImp)
$tabImpressoras.Controls.Add($txtBuscaImp)
$tabImpressoras.Controls.Add($lblResumoImp)
$tabImpressoras.Controls.Add($gridImp)

# Adiciona abas
$tabs.Controls.Add($tabDesligamentos)
$tabs.Controls.Add($tabCredenciais)
$tabs.Controls.Add($tabImpressoras)

# ============================================================
#  STATUS BAR
# ============================================================
$status = New-Object System.Windows.Forms.StatusStrip
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "Pronto."
$status.Items.Add($statusLabel) | Out-Null

# ============================================================
#  NOTIFY ICON
# ============================================================
$notify = New-Object System.Windows.Forms.NotifyIcon
$notify.Icon = [System.Drawing.SystemIcons]::Information
$notify.Visible = $false
$notify.Text = "Monitor de Eventos"

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
$script:UltimoCheck = Get-Date
$script:AlertasIgnorados = @{}

$script:Cores = @{
    41   = [System.Drawing.Color]::LightCoral
    6008 = [System.Drawing.Color]::Khaki
    1001 = [System.Drawing.Color]::Plum
    1074 = [System.Drawing.Color]::LightGreen
    4625 = [System.Drawing.Color]::LightCoral
    4776 = [System.Drawing.Color]::Khaki
    4740 = [System.Drawing.Color]::Plum
    6161 = [System.Drawing.Color]::LightCoral
    808  = [System.Drawing.Color]::Khaki
    307  = [System.Drawing.Color]::LightGreen
}

$script:TipoDesl = @{
    41   = "Kernel-Power"
    6008 = "Desligamento Inesperado"
    1001 = "BSOD"
    1074 = "Desligamento Planejado"
}

$script:TipoCred = @{
    4625 = "Falha de Logon"
    4776 = "Validacao de Credenciais"
    4740 = "Conta Bloqueada"
}

$script:TipoImp = @{
    307  = "Trabalho Enviado"
    6161 = "Falha de Comunicacao"
    808  = "Erro de Impressao"
}

# ============================================================
#  FUNCAO: EXTRAIR DADOS DO EVENTO
# ============================================================
function Get-DadosDoEvento {
    param($Evento)

    $resultado = [PSCustomObject]@{
        Usuario    = "(desconhecido)"
        Workstation = ""
        IpAddress  = ""
        LogonType  = ""
        Status     = ""
        SubStatus  = ""
    }

    try {
        $xml = [xml]$Evento.ToXml()
        if ($xml.Event.EventData -and $xml.Event.EventData.Data) {

            foreach ($nome in @("TargetUserName","SubjectUserName","AccountName","User","UserName")) {
                $no = $xml.Event.EventData.Data | Where-Object { $_.Name -eq $nome } | Select-Object -First 1
                if ($no -and $no.'#text' -and $no.'#text'.Trim() -ne '') {
                    $resultado.Usuario = $no.'#text'.Trim()
                    break
                }
            }

            foreach ($nome in @("WorkstationName","Workstation")) {
                $no = $xml.Event.EventData.Data | Where-Object { $_.Name -eq $nome } | Select-Object -First 1
                if ($no -and $no.'#text') { $resultado.Workstation = $no.'#text'.Trim(); break }
            }

            foreach ($nome in @("IpAddress","ClientAddress","SourceNetworkAddress")) {
                $no = $xml.Event.EventData.Data | Where-Object { $_.Name -eq $nome } | Select-Object -First 1
                if ($no -and $no.'#text') { $resultado.IpAddress = $no.'#text'.Trim(); break }
            }

            $no = $xml.Event.EventData.Data | Where-Object { $_.Name -eq "LogonType" } | Select-Object -First 1
            if ($no -and $no.'#text') { $resultado.LogonType = $no.'#text'.Trim() }

            $no = $xml.Event.EventData.Data | Where-Object { $_.Name -eq "Status" } | Select-Object -First 1
            if ($no -and $no.'#text') { $resultado.Status = $no.'#text'.Trim() }
            $no = $xml.Event.EventData.Data | Where-Object { $_.Name -eq "SubStatus" } | Select-Object -First 1
            if ($no -and $no.'#text') { $resultado.SubStatus = $no.'#text'.Trim() }
        }
    }
    catch { }

    if ($resultado.Usuario -eq "(desconhecido)" -and $Evento.UserId) {
        try {
            $sid = New-Object System.Security.Principal.SecurityIdentifier($Evento.UserId.Value)
            $resultado.Usuario = $sid.Translate([System.Security.Principal.NTAccount]).Value
        }
        catch { $resultado.Usuario = $Evento.UserId.Value }
    }

    return $resultado
}

# ============================================================
#  FUNCAO AUXILIAR: extrair campo do XML de impressora
# ============================================================
function Get-CampoEventoImpressora {
    param($Xml, [string[]]$Nomes)

    foreach ($nome in $Nomes) {
        $no = $Xml.Event.EventData.Data | Where-Object { $_.Name -eq $nome } | Select-Object -First 1
        if ($no -and $no.'#text' -and $no.'#text'.Trim() -ne '') {
            return $no.'#text'.Trim()
        }
    }
    return ""
}

# ============================================================
#  ABA 1: CARREGAR DESLIGAMENTOS
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
                DataHora         = $ev.TimeCreated
                EventoID         = $ev.Id
                Tipo             = $script:TipoDesl[$ev.Id]
                Fonte            = $ev.ProviderName
                Usuario          = $ev.UserId
                Mensagem         = ($ev.Message -replace "`r", " " -replace "`n", " ")
                MensagemCompleta = $ev.Message
            }
        }

        $script:DadosDeslBrutos = @($lista | Sort-Object DataHora -Descending)
        Aplicar-FiltroDesl
        $statusLabel.Text = "Desligamentos: $($script:DadosDeslBrutos.Count) eventos. Exibindo $($script:DadosDeslFiltrados.Count)."
    }
    catch {
        if ($_.Exception.Message -match "No events were found") {
            $script:DadosDeslBrutos = @()
            Aplicar-FiltroDesl
            $statusLabel.Text = "Nenhum evento de desligamento no periodo."
        }
        else {
            $statusLabel.Text = "Erro: $($_.Exception.Message)"
        }
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Aplicar-FiltroDesl {
    $filtroId = $null
    if ($cmbFiltroDesl.SelectedIndex -gt 0) {
        $filtroId = [int]($cmbFiltroDesl.SelectedItem -split ' ')[0]
    }

    $dados = if ($null -eq $filtroId) { $script:DadosDeslBrutos }
             else { $script:DadosDeslBrutos | Where-Object { $_.EventoID -eq $filtroId } }

    $script:DadosDeslFiltrados = @($dados)
    $gridDesl.DataSource = $null

    if ($script:DadosDeslFiltrados.Count -gt 0) {
        $bl = New-Object System.ComponentModel.BindingList[object]
        foreach ($item in $script:DadosDeslFiltrados) { $bl.Add($item) | Out-Null }
        $gridDesl.DataSource = $bl

        if ($gridDesl.Columns.Count -gt 0) {
            $gridDesl.Columns["DataHora"].DefaultCellStyle.Format = "dd/MM/yyyy HH:mm:ss"

            if ($gridDesl.Columns.Contains("MensagemCompleta")) {
                $gridDesl.Columns["MensagemCompleta"].Visible = $false
            }
        }
    }

    $q41   = @($script:DadosDeslFiltrados | Where-Object { $_.EventoID -eq 41 }).Count
    $q6008 = @($script:DadosDeslFiltrados | Where-Object { $_.EventoID -eq 6008 }).Count
    $q1001 = @($script:DadosDeslFiltrados | Where-Object { $_.EventoID -eq 1001 }).Count
    $q1074 = @($script:DadosDeslFiltrados | Where-Object { $_.EventoID -eq 1074 }).Count

    $lblResumoDesl.Text = "Kernel-Power: $q41 | 6008: $q6008 | BSOD: $q1001 | Planejados: $q1074 | Total: $($script:DadosDeslFiltrados.Count)"
}

# ============================================================
#  ABA 2: CARREGAR CREDENCIAIS
# ============================================================
function Carregar-Credenciais {

    $statusLabel.Text = "Consultando eventos de credenciais (log Security)..."
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
            $usuariosAlvo = $txtUsuarioCred.Text.Split(';') |
                            ForEach-Object { $_.Trim() } |
                            Where-Object { $_ -ne '' }
        }

        $lista = foreach ($ev in $eventos) {

            $info = Get-DadosDoEvento -Evento $ev

            if ($usuariosAlvo.Count -gt 0) {
                $bateu = $false
                foreach ($u in $usuariosAlvo) {
                    if ($info.Usuario -like "*$u*") { $bateu = $true; break }
                }
                if (-not $bateu) { continue }
            }

            $statusTxt = ""
            if ($info.Status -or $info.SubStatus) {
                $cod = if ($info.SubStatus) { $info.SubStatus } else { $info.Status }
                $desc = Get-StatusDescricao -Codigo $cod
                $statusTxt = "$cod ($desc)"
            }

            [PSCustomObject]@{
                DataHora         = $ev.TimeCreated
                EventoID         = $ev.Id
                Tipo             = $script:TipoCred[$ev.Id]
                Usuario          = $info.Usuario
                Workstation      = $info.Workstation
                IP               = $info.IpAddress
                LogonType        = $info.LogonType
                Status           = $statusTxt
                Fonte            = $ev.ProviderName
                Mensagem         = ($ev.Message -replace "`r", " " -replace "`n", " ")
                MensagemCompleta = $ev.Message
            }
        }

        $script:DadosCredBrutos = @($lista | Sort-Object DataHora -Descending)
        Aplicar-FiltroCred
        $statusLabel.Text = "Credenciais: $($script:DadosCredBrutos.Count) eventos. Exibindo $($script:DadosCredFiltrados.Count)."

        Detectar-PadraoFalhas
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -match "No events were found") {
            $script:DadosCredBrutos = @()
            Aplicar-FiltroCred
            $statusLabel.Text = "Nenhum evento de credencial no periodo."
        }
        elseif ($msg -match "unauthorized" -or $msg -match "Acesso negado" -or $msg -match "Access is denied") {
            [System.Windows.Forms.MessageBox]::Show(
                "O log 'Security' requer privilegios de Administrador.`r`n`r`nFeche o PowerShell e execute-o como Administrador.",
                "Permissao negada",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            $statusLabel.Text = "Sem permissao para ler o log Security. Rode como Admin."
        }
        else {
            $statusLabel.Text = "Erro: $msg"
        }
    }
    finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Aplicar-FiltroCred {
    $filtroId = $null
    if ($cmbFiltroCred.SelectedIndex -gt 0) {
        $filtroId = [int]($cmbFiltroCred.SelectedItem -split ' ')[0]
    }

    $busca = $txtBuscaCred.Text.Trim()

    $dados = $script:DadosCredBrutos

    if ($null -ne $filtroId) {
        $dados = $dados | Where-Object { $_.EventoID -eq $filtroId }
    }

    if ($busca -ne '') {
        $dados = $dados | Where-Object {
            $_.IP          -like "*$busca*" -or
            $_.Workstation -like "*$busca*" -or
            $_.Usuario     -like "*$busca*"
        }
    }

    $script:DadosCredFiltrados = @($dados)
    $gridCred.DataSource = $null

    if ($script:DadosCredFiltrados.Count -gt 0) {
        $bl = New-Object System.ComponentModel.BindingList[object]
        foreach ($item in $script:DadosCredFiltrados) { $bl.Add($item) | Out-Null }
        $gridCred.DataSource = $bl

        if ($gridCred.Columns.Count -gt 0) {
            $gridCred.Columns["DataHora"].DefaultCellStyle.Format = "dd/MM/yyyy HH:mm:ss"

            if ($gridCred.Columns.Contains("MensagemCompleta")) {
                $gridCred.Columns["MensagemCompleta"].Visible = $false
            }
        }
    }

    $q4625 = @($script:DadosCredFiltrados | Where-Object { $_.EventoID -eq 4625 }).Count
    $q4776 = @($script:DadosCredFiltrados | Where-Object { $_.EventoID -eq 4776 }).Count
    $q4740 = @($script:DadosCredFiltrados | Where-Object { $_.EventoID -eq 4740 }).Count

    $lblResumoCred.Text = "Falhas de Logon: $q4625 | Validacao NTLM: $q4776 | Contas Bloqueadas: $q4740 | Total: $($script:DadosCredFiltrados.Count)"
}

# ============================================================
#  ABA 3: CARREGAR IMPRESSORAS
# ============================================================
function Carregar-Impressoras {

    $statusLabel.Text = "Consultando impressoras..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $form.Refresh()

    # Modo 0: Historico (log de eventos)
    if ($cmbModoImp.SelectedIndex -eq 0) {

        try {
            $ok = Habilitar-LogImpressoras
            if (-not $ok) {
                $statusLabel.Text = "Nao foi possivel acessar o log PrintService. Rode como Admin."
            }

            $dias = [int]$numDias.Value
            $dataCorte = if ($dias -gt 0) { (Get-Date).AddDays(-$dias) } else { $null }

            $filtro = @{
                LogName = 'Microsoft-Windows-PrintService/Operational'
                Id      = 307, 6161, 808
            }
            if ($dataCorte) { $filtro.StartTime = $dataCorte }

            $eventos = Get-WinEvent -FilterHashtable $filtro -MaxEvents 5000 -ErrorAction Stop

            $lista = foreach ($ev in $eventos) {

                $xml = $null
                try { $xml = [xml]$ev.ToXml() } catch { }

                $impressora = ""
                $porta      = ""
                $documento  = ""
                $usuario    = ""
                $tamanho    = ""

                if ($xml) {
                    $impressora = Get-CampoEventoImpressora -Xml $xml -Nomes @("Param3","PrinterName","Name")
                    $porta      = Get-CampoEventoImpressora -Xml $xml -Nomes @("Param4","PortName","Port")
                    $documento  = Get-CampoEventoImpressora -Xml $xml -Nomes @("Param2","DocumentName","Document")
                    $usuario    = Get-CampoEventoImpressora -Xml $xml -Nomes @("Param1","UserName","User")
                    $tamanho    = Get-CampoEventoImpressora -Xml $xml -Nomes @("Param5","Size","Bytes")
                }

                [PSCustomObject]@{
                    DataHora         = $ev.TimeCreated
                    EventoID         = $ev.Id
                    Tipo             = $script:TipoImp[$ev.Id]
                    Impressora       = $impressora
                    Porta            = $porta
                    Documento        = $documento
                    Usuario          = $usuario
                    Tamanho          = $tamanho
                    Fonte            = $ev.ProviderName
                    Mensagem         = ($ev.Message -replace "`r", " " -replace "`n", " ")
                    MensagemCompleta = $ev.Message
                }
            }

            $script:DadosImpBrutos = @($lista | Sort-Object DataHora -Descending)
        }
        catch {
            $msg = $_.Exception.Message
            if ($msg -match "No events were found") {
                $script:DadosImpBrutos = @()
                $statusLabel.Text = "Nenhum evento de impressora no periodo."
            }
            elseif ($msg -match "unauthorized" -or $msg -match "Acesso negado") {
                $script:DadosImpBrutos = @()
                [System.Windows.Forms.MessageBox]::Show(
                    "O log PrintService/Operational requer privilegios de Administrador.`r`n`r`nFeche o PowerShell e execute-o como Administrador.",
                    "Permissao negada",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Warning
                ) | Out-Null
            }
            else {
                $script:DadosImpBrutos = @()
                $statusLabel.Text = "Erro: $msg"
            }
        }
    }
    # Modo 1: Status atual (fila)
    else {

        try {
            $impressoras = Get-Printer -ErrorAction Stop
            $lista = foreach ($imp in $impressoras) {

                $jobs = @()
                try { $jobs = @(Get-PrintJob -PrinterName $imp.Name -ErrorAction SilentlyContinue) } catch { }

                $qtdJobs = $jobs.Count
                $jobsErro = @($jobs | Where-Object { $_.JobStatus -ne "Normal" }).Count

                [PSCustomObject]@{
                    Nome          = $imp.Name
                    Status        = "$($imp.PrinterStatus)"
                    Porta         = $imp.PortName
                    Driver        = $imp.DriverName
                    Compartilhada = if ($imp.Shared) { "Sim" } else { "Nao" }
                    JobsAtivos    = $qtdJobs
                    JobsComErro   = $jobsErro
                    Local         = if ($imp.Shared) { "\\$env:COMPUTERNAME\$($imp.ShareName)" } else { "(local)" }
                }
            }

            $script:DadosImpBrutos = @($lista | Sort-Object Nome)
        }
        catch {
            $script:DadosImpBrutos = @()
            $statusLabel.Text = "Erro ao consultar fila: $($_.Exception.Message)"
        }
    }

    Aplicar-FiltroImp
    $statusLabel.Text = "Impressoras: $($script:DadosImpBrutos.Count) registros. Exibindo $($script:DadosImpFiltrados.Count)."

    $form.Cursor = [System.Windows.Forms.Cursors]::Default
}

function Aplicar-FiltroImp {

    $busca = $txtBuscaImp.Text.Trim()

    $dados = $script:DadosImpBrutos

    if ($busca -ne '') {
        if ($cmbModoImp.SelectedIndex -eq 0) {
            $dados = $dados | Where-Object {
                $_.Impressora -like "*$busca*" -or
                $_.Porta      -like "*$busca*" -or
                $_.Usuario    -like "*$busca*" -or
                $_.Documento  -like "*$busca*"
            }
        }
        else {
            $dados = $dados | Where-Object {
                $_.Nome  -like "*$busca*" -or
                $_.Porta -like "*$busca*"
            }
        }
    }

    $script:DadosImpFiltrados = @($dados)
    $gridImp.DataSource = $null

    if ($script:DadosImpFiltrados.Count -gt 0) {
        $bl = New-Object System.ComponentModel.BindingList[object]
        foreach ($item in $script:DadosImpFiltrados) { $bl.Add($item) | Out-Null }
        $gridImp.DataSource = $bl

        if ($gridImp.Columns.Count -gt 0) {
            if ($cmbModoImp.SelectedIndex -eq 0) {
                $gridImp.Columns["DataHora"].DefaultCellStyle.Format = "dd/MM/yyyy HH:mm:ss"

                if ($gridImp.Columns.Contains("Mensagem")) {
                    $gridImp.Columns["Mensagem"].Visible = $false
                }
                if ($gridImp.Columns.Contains("MensagemCompleta")) {
                    $gridImp.Columns["MensagemCompleta"].Visible = $false
                }
            }
        }
    }

    if ($cmbModoImp.SelectedIndex -eq 0) {
        $qFalhas = @($script:DadosImpFiltrados | Where-Object { $_.EventoID -eq 6161 }).Count
        $qErros  = @($script:DadosImpFiltrados | Where-Object { $_.EventoID -eq 808 }).Count
        $qOk     = @($script:DadosImpFiltrados | Where-Object { $_.EventoID -eq 307 }).Count
        $lblResumoImp.Text = "Falhas de Comunicacao: $qFalhas | Erros: $qErros | Enviados OK: $qOk | Total: $($script:DadosImpFiltrados.Count)"
    }
    else {
        $qOffline = @($script:DadosImpFiltrados | Where-Object { $_.Status -ne "Normal" }).Count
        $qComErro = @($script:DadosImpFiltrados | Where-Object { $_.JobsComErro -gt 0 }).Count
        $lblResumoImp.Text = "Impressoras: $($script:DadosImpFiltrados.Count) | Nao-Normais: $qOffline | Com Jobs em Erro: $qComErro"
    }
}

# ============================================================
#  DETECCAO DE PADRAO (credenciais)
# ============================================================
function Detectar-PadraoFalhas {

    if ($script:DadosCredBrutos.Count -eq 0) { return }

    $falhas = $script:DadosCredBrutos |
              Where-Object { $_.EventoID -eq 4625 } |
              Sort-Object DataHora

    if ($falhas.Count -lt 3) { return }

    $grupos = @{}
    foreach ($f in $falhas) {
        $chave = "$($f.Usuario)|$($f.IP)"
        if (-not $grupos.ContainsKey($chave)) { $grupos[$chave] = @() }
        $grupos[$chave] += $f
    }

    foreach ($chave in $grupos.Keys) {
        if ($script:AlertasIgnorados.ContainsKey($chave)) { continue }

        $lista = $grupos[$chave]
        for ($i = 0; $i -le $lista.Count - 3; $i++) {
            $ini = $lista[$i].DataHora
            $fim = $lista[$i + 2].DataHora
            if (($fim - $ini).TotalMinutes -le 5) {
                $partes = $chave -split '\|'
                $statusLabel.Text = "ALERTA: possivel ataque ou credencial desatualizada ($($partes[0]))"
                $notify.Visible = $true
                $notify.BalloonTipTitle = "Alerta de Seguranca"
                $notify.BalloonTipText = "Usuario $($partes[0]) - 3+ falhas em 5 min`nIP: $($partes[1])"
                $notify.BalloonTipIcon = "Warning"
                $notify.ShowBalloonTip(8000)
                return
            }
        }
    }
}

# ============================================================
#  COLORACAO DOS GRIDS
# ============================================================
$gridDesl.add_CellFormatting({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $dataRow = $gridDesl.Rows[$e.RowIndex]
    if ($dataRow.Cells.Count -le 1) { return }
    $idCell = $dataRow.Cells[1].Value
    if ($null -eq $idCell) { return }
    $id = [int]$idCell
    if ($script:Cores.ContainsKey($id)) {
        $e.CellStyle.BackColor = $script:Cores[$id]
        $e.CellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(
            [Math]::Max(0, $script:Cores[$id].R - 40),
            [Math]::Max(0, $script:Cores[$id].G - 40),
            [Math]::Max(0, $script:Cores[$id].B - 40))
    }
})

$gridCred.add_CellFormatting({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $dataRow = $gridCred.Rows[$e.RowIndex]
    if ($dataRow.Cells.Count -le 1) { return }
    $idCell = $dataRow.Cells[1].Value
    if ($null -eq $idCell) { return }
    $id = [int]$idCell
    if ($script:Cores.ContainsKey($id)) {
        $e.CellStyle.BackColor = $script:Cores[$id]
        $e.CellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(
            [Math]::Max(0, $script:Cores[$id].R - 40),
            [Math]::Max(0, $script:Cores[$id].G - 40),
            [Math]::Max(0, $script:Cores[$id].B - 40))
    }

    if ($id -eq 4625) {
        $userCell = $dataRow.Cells["Usuario"].Value
        $dataCell = $dataRow.Cells["DataHora"].Value
        if ($userCell -and $dataCell) {
            $chaveAlerta = "$userCell|"
            $mesmoDia = @($script:DadosCredFiltrados |
                          Where-Object {
                              $_.EventoID -eq 4625 -and
                              $_.Usuario -eq $userCell -and
                              $_.DataHora.Date -eq $dataCell.Date
                          }).Count
            if ($mesmoDia -ge 3 -and -not $script:AlertasIgnorados.ContainsKey($chaveAlerta)) {
                $e.CellStyle.BackColor = [System.Drawing.Color]::Red
                $e.CellStyle.ForeColor = [System.Drawing.Color]::White
            }
        }
    }
})

$gridImp.add_CellFormatting({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $dataRow = $gridImp.Rows[$e.RowIndex]
    if ($dataRow.Cells.Count -le 1) { return }

    if ($cmbModoImp.SelectedIndex -eq 0) {
        $idCell = $dataRow.Cells[1].Value
        if ($null -eq $idCell) { return }
        $id = [int]$idCell
        if ($script:Cores.ContainsKey($id)) {
            $e.CellStyle.BackColor = $script:Cores[$id]
            $e.CellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(
                [Math]::Max(0, $script:Cores[$id].R - 40),
                [Math]::Max(0, $script:Cores[$id].G - 40),
                [Math]::Max(0, $script:Cores[$id].B - 40))
        }
    }
    else {
        $statusCell = $dataRow.Cells["Status"].Value
        $erroCell   = $dataRow.Cells["JobsComErro"].Value
        if ($erroCell -and [int]$erroCell -gt 0) {
            $e.CellStyle.BackColor = [System.Drawing.Color]::LightCoral
        }
        elseif ($statusCell -and $statusCell -ne "Normal") {
            $e.CellStyle.BackColor = [System.Drawing.Color]::Khaki
        }
        else {
            $e.CellStyle.BackColor = [System.Drawing.Color]::LightGreen
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
    }
    $script:UltimoCheck = Get-Date
})

$btnLimparAlertas.Add_Click({
    $resp = [System.Windows.Forms.MessageBox]::Show(
        "Isso vai remover o destaque vermelho dos alertas atuais.`r`n`r`nContinuar?",
        "Limpar Alertas",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($resp -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    foreach ($d in $script:DadosCredFiltrados | Where-Object { $_.EventoID -eq 4625 }) {
        $chave = "$($d.Usuario)|"
        if (-not $script:AlertasIgnorados.ContainsKey($chave)) {
            $script:AlertasIgnorados[$chave] = $true
        }
    }

    $gridCred.Refresh()
    $statusLabel.Text = "Alertas limpos."
})

$cmbFiltroDesl.Add_SelectedIndexChanged({
    Aplicar-FiltroDesl
    $statusLabel.Text = "Filtro aplicado. Exibindo $($script:DadosDeslFiltrados.Count) evento(s)."
})

$cmbFiltroCred.Add_SelectedIndexChanged({
    Aplicar-FiltroCred
    $statusLabel.Text = "Filtro aplicado. Exibindo $($script:DadosCredFiltrados.Count) evento(s)."
})

$cmbModoImp.Add_SelectedIndexChanged({
    Carregar-Impressoras
})

$txtUsuarioCred.Add_KeyDown({
    param($sender, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $script:Config.UsuariosCred = $txtUsuarioCred.Text
        Salvar-Config -Config $script:Config
        Carregar-Credenciais
        $e.SuppressKeyPress = $true
    }
})

$txtBuscaCred.Add_TextChanged({
    Aplicar-FiltroCred
})

$txtBuscaImp.Add_TextChanged({
    Aplicar-FiltroImp
})

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
    if ($chkAuto.Checked) {
        $timer.Start()
        $statusLabel.Text = "Auto-atualizacao ativada (cada $($numIntervalo.Value) min)."
    } else {
        $timer.Stop()
        $statusLabel.Text = "Auto-atualizacao desativada."
    }
})

# ============================================================
#  DUPLO CLIQUE - DESLIGAMENTOS
# ============================================================
$gridDesl.Add_CellDoubleClick({
    if ($gridDesl.SelectedRows.Count -eq 0) { return }
    $row = $gridDesl.SelectedRows[0]

    $msgCompleta = $row.Cells["MensagemCompleta"].Value
    if ([string]::IsNullOrWhiteSpace($msgCompleta)) {
        $msgCompleta = $row.Cells["Mensagem"].Value
    }

    $campos = [ordered]@{
        "Data/Hora" = $row.Cells["DataHora"].Value
        "Evento ID" = $row.Cells["EventoID"].Value
        "Tipo"      = $row.Cells["Tipo"].Value
        "Fonte"     = $row.Cells["Fonte"].Value
        "Usuario"   = $row.Cells["Usuario"].Value
    }

    Show-DetalhesEvento -Titulo "Detalhes do Evento" -Campos $campos -MensagemCompleta $msgCompleta
})

# ============================================================
#  DUPLO CLIQUE - CREDENCIAIS
# ============================================================
$gridCred.Add_CellDoubleClick({
    if ($gridCred.SelectedRows.Count -eq 0) { return }
    $row = $gridCred.SelectedRows[0]

    $msgCompleta = $row.Cells["MensagemCompleta"].Value
    if ([string]::IsNullOrWhiteSpace($msgCompleta)) {
        $msgCompleta = $row.Cells["Mensagem"].Value
    }

    $campos = [ordered]@{
        "Data/Hora"   = $row.Cells["DataHora"].Value
        "Evento ID"   = $row.Cells["EventoID"].Value
        "Tipo"        = $row.Cells["Tipo"].Value
        "Usuario"     = $row.Cells["Usuario"].Value
        "Workstation" = $row.Cells["Workstation"].Value
        "IP"          = $row.Cells["IP"].Value
        "LogonType"   = $row.Cells["LogonType"].Value
        "Status"      = $row.Cells["Status"].Value
        "Fonte"       = $row.Cells["Fonte"].Value
    }

    Show-DetalhesEvento -Titulo "Detalhes do Evento" -Campos $campos -MensagemCompleta $msgCompleta
})

# ============================================================
#  DUPLO CLIQUE - IMPRESSORAS
# ============================================================
$gridImp.Add_CellDoubleClick({
    if ($gridImp.SelectedRows.Count -eq 0) { return }
    $row = $gridImp.SelectedRows[0]

    if ($cmbModoImp.SelectedIndex -eq 0) {
        $msgCompleta = $row.Cells["MensagemCompleta"].Value
        if ([string]::IsNullOrWhiteSpace($msgCompleta)) {
            $msgCompleta = $row.Cells["Mensagem"].Value
        }
        $campos = [ordered]@{
            "Data/Hora"  = $row.Cells["DataHora"].Value
            "Evento ID"  = $row.Cells["EventoID"].Value
            "Tipo"       = $row.Cells["Tipo"].Value
            "Impressora" = $row.Cells["Impressora"].Value
            "Porta"      = $row.Cells["Porta"].Value
            "Documento"  = $row.Cells["Documento"].Value
            "Usuario"    = $row.Cells["Usuario"].Value
            "Fonte"      = $row.Cells["Fonte"].Value
        }
    }
    else {
        $msgCompleta = "Modo 'Status atual' nao possui mensagem de evento."
        $campos = [ordered]@{
            "Nome"          = $row.Cells["Nome"].Value
            "Status"        = $row.Cells["Status"].Value
            "Porta"         = $row.Cells["Porta"].Value
            "Driver"        = $row.Cells["Driver"].Value
            "Compartilhada" = $row.Cells["Compartilhada"].Value
            "JobsAtivos"    = $row.Cells["JobsAtivos"].Value
            "JobsComErro"   = $row.Cells["JobsComErro"].Value
            "Local"         = $row.Cells["Local"].Value
        }
    }

    Show-DetalhesEvento -Titulo "Detalhes" -Campos $campos -MensagemCompleta $msgCompleta
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
    $script:UltimoCheck = Get-Date
})

if ($chkAuto.Checked) { $timer.Start() }

# ============================================================
#  FECHAMENTO
# ============================================================
$form.Add_FormClosing({
    $timer.Stop()
    $notify.Visible = $false
    $notify.Dispose()
})

# ============================================================
#  INICIALIZACAO
# ============================================================
$form.Add_Shown({
    Carregar-Desligamentos
})

[void]$form.ShowDialog()
$form.Dispose()