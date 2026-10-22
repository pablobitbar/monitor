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

    try {
        $extractDir = Join-Path $libDir "pdfpig_extract"
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue }

        $zipPath = $nupkgPath -replace '\.nupkg$', '.zip'
        Move-Item $nupkgPath $zipPath -Force
        Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue

        $pastaAlvo = Get-ChildItem -Path $extractDir -Recurse -Directory |
            Where-Object { $_.Name -eq "netstandard2.0" } |
            Select-Object -First 1

        if (-not $pastaAlvo) {
            $pastaAlvo = Get-ChildItem -Path $extractDir -Recurse -Directory |
                Where-Object { $_.FullName -match '\\lib\\' } |
                Select-Object -First 1
        }

        if (-not $pastaAlvo) { throw "Nao encontrei a pasta de DLLs no pacote" }

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
    "Sincronizacao","Editando","Sangria","Suprimento",
    "Itens","Libera Cartao/Mesa","Pagamento","Bloqueio",
    "Inserindo","Libera","Transferencias","Transf. Prod"
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

# ------------------------------------------------------------
#  LIMPEZA DO TEXTO EXTRAIDO (remove rodapes/cabecalhos do PDF)
# ------------------------------------------------------------
function Limpar-TextoPdf {
    param([string]$Texto)
    if ([string]::IsNullOrWhiteSpace($Texto)) { return $Texto }

    # Rodape "Pagina: X / Y" (com ou sem acento)
    $Texto = [regex]::Replace($Texto, 'P[áa]gina:\s*\d+\s*/\s*\d+', ' ')
    # URL do rodape
    $Texto = [regex]::Replace($Texto, 'www\.bitbar\.com\.br', ' ')
    # Cabecalho da tabela (com acento ou '..' quando o PDF perde os acentos)
    $Texto = [regex]::Replace($Texto, 'Usu[áa]rioTipoComputadorDescri[çc][ãa]oHora', ' ')
    $Texto = [regex]::Replace($Texto, 'Usu\.rioTipoComputadorDescri\.\.oHora', ' ')
    # Titulo solto
    $Texto = [regex]::Replace($Texto, 'Log de Altera[çc][õo]es', ' ')

    # Normaliza espacos multiplos em uma linha (preserva quebras)
    $Texto = [regex]::Replace($Texto, '[ \t]+', ' ')

    return $Texto
}

function Parse-LogBitBar {
    param([string]$TextoCompleto)

    $registros = New-Object System.Collections.ArrayList
    if ([string]::IsNullOrWhiteSpace($TextoCompleto)) { return $registros }

    # Mantem a estrategia da versao funcional: separar registros pelo padrao
    # reconhecivel, sem exigir data ou milissegundos em todos os eventos.
    $tipos = 'Geral|Inserindo|Editando|Libera|Fiscal|Receive|Sincronizacao|Abertura|Fechamento|Clientes|Itens|Bloqueio|Pagamento|Transf\.\s*Prod'
    $inicioRegistro = '(?=[\p{L}][\p{L}\p{N}._'' -]*?(?:' + $tipos + ')[\p{L}\p{N}._-]*\d{2}:\d{2}:\d{2}(?:\.\d+)?)'
    $textoNormalizado = [regex]::Replace($TextoCompleto, $inicioRegistro, "`n")

    # Cabecalhos de secao tambem podem estar colados ao registro anterior.
    $textoNormalizado = [regex]::Replace(
        $textoNormalizado,
        '(?=(?:Abertura|Fechamento|Clientes|Fiscal|Receive|Sincronizacao|Editando|Sangria|Suprimento|Itens|Libera Cartao/Mesa|Transferencias|Transf\.\s*Prod)UsuárioTipoComputadorDescriçãoHora)',
        "`n"
    )

    $linhas = $textoNormalizado -split "`r?`n"
    $secaoAtual = "Geral"

    # Regex da versao que funcionava: aceita data opcional e horario com ou sem milissegundos.
    $regexColado = [regex]'^(?:(?<data>\d{2}/\d{2}/\d{4}))?(?<usuario>[\p{L}][\p{L}\p{N}._'' -]*?)(?<tipo>Geral|Inserindo|Editando|Libera|Fiscal|Receive|Sincronizacao|Abertura|Fechamento|Clientes|Itens|Bloqueio|Pagamento|Transf\.\s*Prod)(?<comp>[\p{L}\p{N}._-]*?)(?<hora>\d{2}:\d{2}:\d{2}(?:\.\d+)?)(?<desc>.*)$'
    $regexComEspacos = [regex]'^(?:(?<data>\d{2}/\d{2}/\d{4})\s*)?(?<usuario>[\p{L}][\p{L}\p{N}._'' -]*?)\s+(?<tipo>[\p{L}]+)\s+(?<comp>[\p{L}\p{N}._-]+)?\s*(?<hora>\d{2}:\d{2}:\d{2}(?:\.\d+)?)\s*(?<desc>.*)$'

    foreach ($linhaBruta in $linhas) {
        $linha = $linhaBruta.Trim()
        if (-not $linha) { continue }

        if ($linha -match '^(Abertura|Fechamento|Clientes|Fiscal|Itens|Receive|Sincronizacao|Sangria|Suprimento|Libera Cartao/Mesa|Transferencias|Transf\.\s*Prod)$') {
            $secaoAtual = $Matches[1]
            continue
        }
        if ($linha -match '^(UsuárioTipoComputadorDescriçãoHora|Usu.rioTipoComputadorDescri..oHora|Página:|Log de Alterações|www\.bitbar\.com\.br)') { continue }

        $m = $regexColado.Match($linha)
        if (-not $m.Success) { $m = $regexComEspacos.Match($linha) }
        if (-not $m.Success) { continue }

        $data = $m.Groups['data'].Value
        $hora = $m.Groups['hora'].Value
        $user = $m.Groups['usuario'].Value.Trim()
        $tipo = $m.Groups['tipo'].Value.Trim()
        $comp = $m.Groups['comp'].Value
        $desc = $m.Groups['desc'].Value.Trim()

        if ([string]::IsNullOrWhiteSpace($user) -or [string]::IsNullOrWhiteSpace($hora)) { continue }

        # Extrai mesa/comanda para alimentar o filtro avancado sem alterar a descricao original.
        $mesaComanda = ""
        $mMesa = [regex]::Match($desc, '"nro_mesa"\s*:\s*"([^"]*)"')
        if ($mMesa.Success -and $mMesa.Groups[1].Value.Trim() -ne "") {
            $mesaComanda = $mMesa.Groups[1].Value.Trim()
        }
        if (-not $mesaComanda) {
            $mComanda = [regex]::Match($desc, '"comandas"\s*:\s*\[([^\]]+)\]')
            if ($mComanda.Success) { $mesaComanda = $mComanda.Groups[1].Value.Trim() }
        }
        if (-not $mesaComanda) {
            $mComanda2 = [regex]::Match($desc, 'comandas?"?\s*:?\s*\[?(\d+)')
            if ($mComanda2.Success) { $mesaComanda = $mComanda2.Groups[1].Value }
        }
        if (-not $mesaComanda) {
            $mMesa2 = [regex]::Match($desc, 'mesa\s+(\d+)')
            if ($mMesa2.Success) { $mesaComanda = $mMesa2.Groups[1].Value }
        }

        # --- Separacao: Descricao humana x Payload JSON ---
        $jsonPayload = $null
        $descHumana = $desc
        $jsonMatch = [regex]::Match($desc, '\{.*\}')
        if ($jsonMatch.Success) {
            try {
                $jsonPayload = $jsonMatch.Value | ConvertFrom-Json
                $descHumana = $desc.Substring(0, $jsonMatch.Index).Trim()
                $sobra = $desc.Substring($jsonMatch.Index + $jsonMatch.Length).Trim()
                if ($sobra -ne '') {
                    $descHumana = ("$descHumana $sobra").Trim()
                }
                if ($descHumana -eq '') { $descHumana = $tipo }
            } catch {
                $jsonPayload = $null
                $descHumana = $desc
            }
        }

        [void]$registros.Add([PSCustomObject]@{
            Secao        = $secaoAtual
            Data         = $data
            Hora         = $hora
            DataHora     = if ($data) { "$data $hora" } else { $hora }
            Usuario      = $user
            Computador   = $comp
            Tipo         = $tipo
            MesaComanda  = $mesaComanda
            Descricao    = $descHumana      # <-- limpa
            DescricaoRaw = $desc            # <-- original
            Payload      = $jsonPayload
        })
    }

    return $registros
}

# ============================================================
#  FUNCOES AUXILIARES DE CLASSIFICACAO (ERRO / SUCESSO)
# ============================================================
function Test-ErroLog {
    param([string]$Descricao)
    if ([string]::IsNullOrWhiteSpace($Descricao)) { return $false }
    return ($Descricao -match '"sucesso"\s*:\s*false' -or
            $Descricao -match '"codigo_erro"\s*:\s*[1-9]' -or
            $Descricao -match '"erro"\s*:' -or
            $Descricao -match 'n\p{L}o encontrado' -or
            $Descricao -match 'bloqueado' -or
            $Descricao -match 'ultrapassou o limite' -or
            $Descricao -match 'ERRO:' -or
            $Descricao -match 'n\p{L}o existe')
}

function Test-SucessoLog {
    param([string]$Descricao)
    if ([string]::IsNullOrWhiteSpace($Descricao)) { return $false }
    return ($Descricao -match '"sucesso"\s*:\s*true' -or
            $Descricao -match '"codigo_erro"\s*:\s*0')
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
    $g.AutoSizeColumnsMode = "None"
    $g.AutoSizeRowsMode = "None"
    $g.RowHeadersVisible = $false
    $g.Anchor = "Top,Bottom,Left,Right"
    $g.BackgroundColor = [System.Drawing.Color]::White
    $g.BorderStyle = "FixedSingle"
    $g.EnableHeadersVisualStyles = $false
    # Mantem as barras horizontal e vertical disponiveis quando o conteudo exceder a area visivel.
    $g.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
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
$form.Text = "Monitor Logs"
$form.Size = New-Object System.Drawing.Size(1500, 900)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(1200, 700)
$form.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
$form.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# ============================================================
#  CONTROLES DE TOPO
# ============================================================
$lblPeriodo = New-Object System.Windows.Forms.Label
$lblPeriodo.Text = "Ultimos (dias):"
$lblPeriodo.Location = New-Object System.Drawing.Point(235, 12)
$lblPeriodo.Size = New-Object System.Drawing.Size(90, 20)

$numDias = New-Object System.Windows.Forms.NumericUpDown
$numDias.Location = New-Object System.Drawing.Point(325, 10)
$numDias.Size = New-Object System.Drawing.Size(60, 24)
$numDias.Minimum = 0
$numDias.Maximum = 3650
$numDias.Value = [int]$script:Config.Dias

$btnAtualizarTudo = New-Object System.Windows.Forms.Button
$btnAtualizarTudo.Text = "Atualizar"
$btnAtualizarTudo.Location = New-Object System.Drawing.Point(395, 9)
$btnAtualizarTudo.Size = New-Object System.Drawing.Size(90, 26)

$btnLimparAlertas = New-Object System.Windows.Forms.Button
$btnLimparAlertas.Text = "Limpar Alertas"
$btnLimparAlertas.Location = New-Object System.Drawing.Point(490, 9)
$btnLimparAlertas.Size = New-Object System.Drawing.Size(115, 26)

$lblIntervalo = New-Object System.Windows.Forms.Label
$lblIntervalo.Text = "Auto (min):"
$lblIntervalo.Location = New-Object System.Drawing.Point(620, 12)
$lblIntervalo.Size = New-Object System.Drawing.Size(70, 20)

$numIntervalo = New-Object System.Windows.Forms.NumericUpDown
$numIntervalo.Location = New-Object System.Drawing.Point(690, 10)
$numIntervalo.Size = New-Object System.Drawing.Size(55, 24)
$numIntervalo.Minimum = 1
$numIntervalo.Maximum = 1440
$numIntervalo.Value = [int]$script:Config.IntervaloMin

$chkAuto = New-Object System.Windows.Forms.CheckBox
$chkAuto.Text = "Auto-atualizar"
$chkAuto.Location = New-Object System.Drawing.Point(755, 12)
$chkAuto.Size = New-Object System.Drawing.Size(110, 22)
$chkAuto.Checked = [bool]$script:Config.AlertaAtivo

# ============================================================
#  ABAS
# ============================================================
$tabs = New-Object System.Windows.Forms.TabControl
$tabs.Location = New-Object System.Drawing.Point(230, 112)
$tabs.Size = New-Object System.Drawing.Size(1240, 725)
$tabs.Anchor = "Top,Bottom,Left,Right"
$tabs.Appearance = "FlatButtons"
$tabs.ItemSize = New-Object System.Drawing.Size(1, 1)
$tabs.SizeMode = "Fixed"

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

$gridImp = New-GridPadrao -X 10 -Y 86 -W 1280 -H 610

# Ferramenta nativa para inspecionar arquivos do spool de impressao (.SPL)
$btnAnalisarSpool = New-Object System.Windows.Forms.Button
$btnAnalisarSpool.Text = "Analisar arquivo de impressao (.SPL)"
$btnAnalisarSpool.Location = New-Object System.Drawing.Point(10, 47)
$btnAnalisarSpool.Size = New-Object System.Drawing.Size(210, 30)
$btnAnalisarSpool.Anchor = "Top,Left"
$btnAnalisarSpool.FlatStyle = "Flat"
$btnAnalisarSpool.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$btnAnalisarSpool.ForeColor = [System.Drawing.Color]::White
$btnAnalisarSpool.FlatAppearance.BorderSize = 0

# Exportacao e copia rapida da lista de impressoras
$btnSalvarListaImp = New-Object System.Windows.Forms.Button
$btnSalvarListaImp.Text = "Salvar lista TXT"
$btnSalvarListaImp.Location = New-Object System.Drawing.Point(230, 47)
$btnSalvarListaImp.Size = New-Object System.Drawing.Size(125, 30)
$btnSalvarListaImp.Anchor = "Top,Left"
$btnSalvarListaImp.FlatStyle = "Flat"
$btnSalvarListaImp.BackColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
$btnSalvarListaImp.ForeColor = [System.Drawing.Color]::White
$btnSalvarListaImp.FlatAppearance.BorderSize = 0

$btnCopiarListaImp = New-Object System.Windows.Forms.Button
$btnCopiarListaImp.Text = "Copiar lista (Ctrl+C)"
$btnCopiarListaImp.Location = New-Object System.Drawing.Point(365, 47)
$btnCopiarListaImp.Size = New-Object System.Drawing.Size(155, 30)
$btnCopiarListaImp.Anchor = "Top,Left"
$btnCopiarListaImp.FlatStyle = "Flat"
$btnCopiarListaImp.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$btnCopiarListaImp.ForeColor = [System.Drawing.Color]::White
$btnCopiarListaImp.FlatAppearance.BorderSize = 0

# Abrir a interface web da impressora selecionada (quando a porta revelar IP/host)
$btnAbrirWebImp = New-Object System.Windows.Forms.Button
$btnAbrirWebImp.Text = "Abrir pagina web"
$btnAbrirWebImp.Location = New-Object System.Drawing.Point(530, 47)
$btnAbrirWebImp.Size = New-Object System.Drawing.Size(145, 30)
$btnAbrirWebImp.Anchor = "Top,Left"
$btnAbrirWebImp.FlatStyle = "Flat"
$btnAbrirWebImp.BackColor = [System.Drawing.Color]::FromArgb(22, 101, 52)
$btnAbrirWebImp.ForeColor = [System.Drawing.Color]::White
$btnAbrirWebImp.FlatAppearance.BorderSize = 0

# Envia uma comanda de teste diretamente para a impressora selecionada.
$btnTesteComandaImp = New-Object System.Windows.Forms.Button
$btnTesteComandaImp.Text = "Teste individual de comanda"
$btnTesteComandaImp.Location = New-Object System.Drawing.Point(685, 47)
$btnTesteComandaImp.Size = New-Object System.Drawing.Size(190, 30)
$btnTesteComandaImp.Anchor = "Top,Left"
$btnTesteComandaImp.FlatStyle = "Flat"
$btnTesteComandaImp.BackColor = [System.Drawing.Color]::FromArgb(124, 58, 237)
$btnTesteComandaImp.ForeColor = [System.Drawing.Color]::White
$btnTesteComandaImp.FlatAppearance.BorderSize = 0

$btnAnalisarSpool.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Selecionar arquivo de impressao do spooler"
    $dlg.Filter = "Arquivos de spool (*.spl;*.prn;*.dat)|*.spl;*.prn;*.dat|Todos os arquivos (*.*)|*.*"
    $dlg.CheckFileExists = $true
    # Abrir diretamente na pasta padrao dos trabalhos de impressao do Windows.
    $pastaSpool = Join-Path $env:windir "System32\spool\PRINTERS"
    if (Test-Path -LiteralPath $pastaSpool -PathType Container) {
        $dlg.InitialDirectory = $pastaSpool
    }
    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { $dlg.Dispose(); return }
    $caminho = $dlg.FileName
    $dlg.Dispose()

    $previewBitmap = $null
    $metafile = $null
    $previewStream = $null
    try {
        $bytes = [System.IO.File]::ReadAllBytes($caminho)
        if ($bytes.Length -eq 0) { throw "O arquivo esta vazio." }
        $tamanho = $bytes.Length
        $ext = [System.IO.Path]::GetExtension($caminho).ToUpperInvariant()
        $formato = "Formato de spool nao identificado"
        $diagnostico = "O Windows nao conseguiu confirmar um formato grafico diretamente renderizavel neste arquivo."
        $textoEncontrado = New-Object System.Collections.Generic.List[string]
        $ascii = [System.Text.Encoding]::ASCII.GetString($bytes)
        if ($ascii.Contains("%PDF")) { $formato = "PDF incorporado detectado" }
        elseif ($ascii.Contains("@PJL") -or $ascii.Contains("PCL")) { $formato = "Possiveis comandos PCL/PJL" }
        elseif ($ascii.Contains("%!") -or $ascii.Contains("PostScript")) { $formato = "Possivel PostScript" }

        # Um registro EMF valido tem a assinatura 0x464D4520 (bytes " EMF")
        # no deslocamento 40 a partir do inicio do registro EMR_HEADER.
        # Em arquivos SPL, o EMF pode estar encapsulado depois de dados de spool.
        $emfStart = -1
        for ($i = 40; $i -lt ($bytes.Length - 44); $i++) {
            if ($bytes[$i] -eq 0x20 -and $bytes[$i+1] -eq 0x45 -and $bytes[$i+2] -eq 0x4D -and $bytes[$i+3] -eq 0x46) {
                $candidate = $i - 40
                if ($candidate -ge 0 -and $candidate + 88 -lt $bytes.Length) {
                    $recordType = [BitConverter]::ToUInt32($bytes, $candidate)
                    $headerSize = [BitConverter]::ToUInt32($bytes, $candidate + 4)
                    $signature = [BitConverter]::ToUInt32($bytes, $candidate + 40)
                    if ($recordType -eq 1 -and $headerSize -ge 88 -and $signature -eq 0x464D4520) {
                        $emfStart = $candidate
                        break
                    }
                }
            }
        }

        $viewer = New-Object System.Windows.Forms.Form
        $viewer.Text = "Pre-visualizacao de impressao - $([System.IO.Path]::GetFileName($caminho))"
        $viewer.Size = New-Object System.Drawing.Size(1180, 820)
        $viewer.MinimumSize = New-Object System.Drawing.Size(850, 600)
        $viewer.StartPosition = "CenterParent"
        $viewer.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
        $viewer.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)

        $top = New-Object System.Windows.Forms.Panel
        $top.Dock = 'Top'; $top.Height = 72
        $top.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $lblTitle = New-Object System.Windows.Forms.Label
        $lblTitle.Text = "PRE-VISUALIZACAO DO TRABALHO DE IMPRESSAO"
        $lblTitle.Location = New-Object System.Drawing.Point(16, 10)
        $lblTitle.Size = New-Object System.Drawing.Size(800, 25)
        $lblTitle.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
        $lblTitle.ForeColor = [System.Drawing.Color]::White
        $lblInfo = New-Object System.Windows.Forms.Label
        $lblInfo.Text = ("{0:N0} bytes  |  {1}" -f $tamanho, $formato)
        $lblInfo.Location = New-Object System.Drawing.Point(17, 39)
        $lblInfo.Size = New-Object System.Drawing.Size(1000, 22)
        $lblInfo.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
        $top.Controls.AddRange(@($lblTitle, $lblInfo))

        $split = New-Object System.Windows.Forms.SplitContainer
        $split.Dock = 'Fill'; $split.Orientation = 'Vertical'; $split.SplitterDistance = 800
        $split.BackColor = [System.Drawing.Color]::FromArgb(51, 65, 85)

        $canvas = New-Object System.Windows.Forms.Panel
        $canvas.Dock = 'Fill'; $canvas.AutoScroll = $true
        $canvas.BackColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
        $pic = New-Object System.Windows.Forms.PictureBox
        $pic.Location = New-Object System.Drawing.Point(20, 20)
        $pic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
        $pic.BackColor = [System.Drawing.Color]::White
        $pic.BorderStyle = 'FixedSingle'
        $pic.Size = New-Object System.Drawing.Size(720, 680)
        $canvas.Controls.Add($pic)
        $split.Panel1.Controls.Add($canvas)

        $right = New-Object System.Windows.Forms.Panel
        $right.Dock = 'Fill'; $right.Padding = New-Object System.Windows.Forms.Padding(12)
        $right.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
        $lblStatus = New-Object System.Windows.Forms.Label
        $lblStatus.Dock = 'Top'; $lblStatus.Height = 90
        $lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
        $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(250, 204, 21)
        $lblStatus.Text = "PRE-VISUALIZACAO NAO DISPONIVEL`r`n"
        $txtDiag = New-Object System.Windows.Forms.TextBox
        $txtDiag.Multiline = $true; $txtDiag.ReadOnly = $true; $txtDiag.Dock = 'Fill'
        $txtDiag.ScrollBars = 'Vertical'; $txtDiag.WordWrap = $true
        $txtDiag.Font = New-Object System.Drawing.Font('Consolas', 9)
        $txtDiag.BackColor = [System.Drawing.Color]::FromArgb(11, 18, 32)
        $txtDiag.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
        $right.Controls.Add($txtDiag); $right.Controls.Add($lblStatus)
        $split.Panel2.Controls.Add($right)

        $bottom = New-Object System.Windows.Forms.Panel
        $bottom.Dock = 'Bottom'; $bottom.Height = 48
        $bottom.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $btnClose = New-Object System.Windows.Forms.Button
        $btnClose.Text = 'Fechar'; $btnClose.Size = New-Object System.Drawing.Size(100, 30)
        $btnClose.Location = New-Object System.Drawing.Point(1045, 9)
        $btnClose.Anchor = 'Right,Top'; $btnClose.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $btnClose.FlatStyle = 'Flat'; $btnClose.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
        $btnClose.ForeColor = [System.Drawing.Color]::White
        $bottom.Controls.Add($btnClose)

        $details = New-Object System.Collections.Generic.List[string]
        $details.Add("Arquivo: $caminho")
        $details.Add(("Tamanho: {0:N0} bytes ({1:N2} KB)" -f $tamanho, ($tamanho / 1KB)))
        $details.Add("Extensao: $ext")
        $details.Add("Formato: $formato")
        $details.Add("")

        if ($emfStart -ge 0) {
            try {
                $emfBytes = New-Object byte[] ($bytes.Length - $emfStart)
                [Array]::Copy($bytes, $emfStart, $emfBytes, 0, $emfBytes.Length)
                $previewStream = New-Object System.IO.MemoryStream(, $emfBytes)
                $metafile = New-Object System.Drawing.Imaging.Metafile($previewStream)
                $unit = [System.Drawing.GraphicsUnit]::Pixel
                $bounds = $metafile.GetBounds([ref]$unit)
                $w = [Math]::Max(1, [int][Math]::Ceiling($bounds.Width))
                $h = [Math]::Max(1, [int][Math]::Ceiling($bounds.Height))
                if ($w -gt 10000 -or $h -gt 10000 -or ($w * [double]$h) -gt 50000000) { throw "Dimensoes EMF fora do limite seguro para pre-visualizacao: ${w}x${h}." }
                $previewBitmap = New-Object System.Drawing.Bitmap($w, $h)
                $g = [System.Drawing.Graphics]::FromImage($previewBitmap)
                $g.Clear([System.Drawing.Color]::White)
                $g.DrawImage($metafile, 0, 0, $w, $h)
                $g.Dispose()
                $pic.Image = $previewBitmap
                $pic.Size = New-Object System.Drawing.Size(720, [Math]::Max(500, [int](680 * ($h / [double]$w))))
                $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(134, 239, 172)
                $lblStatus.Text = "PRE-VISUALIZACAO GERADA`r`nEMF renderizado pelo GDI+ do Windows."
                $details.Add("Resultado: EMF localizado e renderizado.")
                $details.Add("Inicio do EMF no SPL: offset $emfStart")
                $details.Add("Dimensoes renderizadas: ${w} x ${h} pixels")
                $details.Add("Orientacao aproximada: " + $(if ($w -gt $h) { 'Paisagem' } else { 'Retrato' }))
                $details.Add("")
                $details.Add("Nota: isto representa o EMF incorporado localizado no arquivo. O driver ou spooler pode aplicar outras transformacoes na impressao final.")
            } catch {
                $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(253, 186, 116)
                $lblStatus.Text = "EMF DETECTADO, MAS NAO FOI POSSIVEL RENDERIZAR"
                $details.Add("Falha ao renderizar EMF: $($_.Exception.Message)")
                $details.Add("O SPL pode conter um encapsulamento de spool que exige processamento adicional.")
            }
        } else {
            $details.Add("Nao foi encontrado um cabecalho EMF estruturalmente valido no arquivo.")
            $details.Add("O arquivo pode conter PCL, dados RAW do driver ou outro formato de spool.")
            $details.Add("Para esses formatos, uma pre-visualizacao fiel depende de interpretar o formato especifico; nao e seguro converter bytes arbitrarios em imagem.")
        }

        $details.Add("")
        $details.Add("===== TEXTO ASCII RECONHECIVEL (AMOSTRA) =====")
        $sb = New-Object System.Text.StringBuilder
        $countStrings = 0
        foreach ($b in $bytes) {
            if (($b -ge 32 -and $b -le 126) -or $b -eq 9) { [void]$sb.Append([char]$b) }
            else {
                if ($sb.Length -ge 5 -and $countStrings -lt 250) { $details.Add($sb.ToString()); $countStrings++ }
                [void]$sb.Clear()
            }
        }
        if ($sb.Length -ge 5 -and $countStrings -lt 250) { $details.Add($sb.ToString()) }
        $txtDiag.Text = $details -join [Environment]::NewLine

        $viewer.Controls.Add($split)
        $viewer.Controls.Add($top)
        $viewer.Controls.Add($bottom)
        $viewer.AcceptButton = $btnClose
        [void]$viewer.ShowDialog($form)
        $viewer.Dispose()
        $statusLabel.Text = "Analise de impressao concluida: $([System.IO.Path]::GetFileName($caminho))"
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel analisar o arquivo:`r`n$($_.Exception.Message)", "Analise de impressao", "OK", "Error") | Out-Null
    } finally {
        if ($metafile) { $metafile.Dispose() }
        if ($previewStream) { $previewStream.Dispose() }
        if ($previewBitmap) { $previewBitmap.Dispose() }
    }
})

$tabImpressoras.Controls.Add($lblModoImp)
$tabImpressoras.Controls.Add($cmbModoImp)
$tabImpressoras.Controls.Add($lblFiltroImp)
$tabImpressoras.Controls.Add($txtBuscaImp)
$tabImpressoras.Controls.Add($lblResumoImp)
$tabImpressoras.Controls.Add($btnAnalisarSpool)
$tabImpressoras.Controls.Add($btnSalvarListaImp)
$tabImpressoras.Controls.Add($btnCopiarListaImp)
$tabImpressoras.Controls.Add($btnAbrirWebImp)
$tabImpressoras.Controls.Add($btnTesteComandaImp)
$tabImpressoras.Controls.Add($gridImp)

# ============================================================
#  ABA 4 - LOG DO SISTEMA (BITBAR) - COM FILTROS AVANCADOS
# ============================================================
$tabLogSistema = New-Object System.Windows.Forms.TabPage
$tabLogSistema.Text = "Log do Sistema"
$tabLogSistema.BackColor = [System.Drawing.Color]::White

# ----- Linha 1: abrir PDF / nome / filtro sessao / limpar -----
$btnAbrirPdf = New-Object System.Windows.Forms.Button
$btnAbrirPdf.Text = "Abrir PDF do Log"
$btnAbrirPdf.Location = New-Object System.Drawing.Point(10, 10)
$btnAbrirPdf.Size = New-Object System.Drawing.Size(130, 28)

$btnConectarFirebird = New-Object System.Windows.Forms.Button
$btnConectarFirebird.Text = "Consultar Firebird"
$btnConectarFirebird.Location = New-Object System.Drawing.Point(150, 10)
$btnConectarFirebird.Size = New-Object System.Drawing.Size(130, 28)

$lblArquivo = New-Object System.Windows.Forms.Label
$lblArquivo.Text = "Nenhum arquivo carregado."
$lblArquivo.Location = New-Object System.Drawing.Point(290, 15)
$lblArquivo.Size = New-Object System.Drawing.Size(350, 20)
$lblArquivo.ForeColor = [System.Drawing.Color]::DimGray

$lblFiltroLog = New-Object System.Windows.Forms.Label
$lblFiltroLog.Text = "Filtrar sessao:"
$lblFiltroLog.Location = New-Object System.Drawing.Point(660, 15)
$lblFiltroLog.Size = New-Object System.Drawing.Size(90, 20)

$txtFiltroLog = New-Object System.Windows.Forms.TextBox
$txtFiltroLog.Location = New-Object System.Drawing.Point(755, 12)
$txtFiltroLog.Size = New-Object System.Drawing.Size(180, 24)
$txtFiltroLog.Text = ""

$btnLimparFiltrosLog = New-Object System.Windows.Forms.Button
$btnLimparFiltrosLog.Text = "Limpar Filtros"
$btnLimparFiltrosLog.Location = New-Object System.Drawing.Point(945, 11)
$btnLimparFiltrosLog.Size = New-Object System.Drawing.Size(115, 26)

# ----- Linha 2: hora, mesa, usuario, tipo, checkboxes -----
$lblHoraDe = New-Object System.Windows.Forms.Label
$lblHoraDe.Text = "Hora de:"
$lblHoraDe.Location = New-Object System.Drawing.Point(10, 45)
$lblHoraDe.Size = New-Object System.Drawing.Size(55, 20)

$txtHoraDe = New-Object System.Windows.Forms.TextBox
$txtHoraDe.Location = New-Object System.Drawing.Point(70, 43)
$txtHoraDe.Size = New-Object System.Drawing.Size(70, 24)
$txtHoraDe.Text = "00:00"

$lblHoraAte = New-Object System.Windows.Forms.Label
$lblHoraAte.Text = "ate:"
$lblHoraAte.Location = New-Object System.Drawing.Point(145, 45)
$lblHoraAte.Size = New-Object System.Drawing.Size(28, 20)

$txtHoraAte = New-Object System.Windows.Forms.TextBox
$txtHoraAte.Location = New-Object System.Drawing.Point(175, 43)
$txtHoraAte.Size = New-Object System.Drawing.Size(70, 24)
$txtHoraAte.Text = "23:59"

$lblMesa = New-Object System.Windows.Forms.Label
$lblMesa.Text = "Mesa/Comanda:"
$lblMesa.Location = New-Object System.Drawing.Point(260, 45)
$lblMesa.Size = New-Object System.Drawing.Size(95, 20)

$txtMesa = New-Object System.Windows.Forms.TextBox
$txtMesa.Location = New-Object System.Drawing.Point(358, 43)
$txtMesa.Size = New-Object System.Drawing.Size(100, 24)
$txtMesa.Text = ""

$lblUsuarioLog = New-Object System.Windows.Forms.Label
$lblUsuarioLog.Text = "Usuario:"
$lblUsuarioLog.Location = New-Object System.Drawing.Point(470, 45)
$lblUsuarioLog.Size = New-Object System.Drawing.Size(55, 20)

$txtUsuarioLog = New-Object System.Windows.Forms.TextBox
$txtUsuarioLog.Location = New-Object System.Drawing.Point(528, 43)
$txtUsuarioLog.Size = New-Object System.Drawing.Size(120, 24)

$lblTipoLog = New-Object System.Windows.Forms.Label
$lblTipoLog.Text = "Tipo:"
$lblTipoLog.Location = New-Object System.Drawing.Point(660, 45)
$lblTipoLog.Size = New-Object System.Drawing.Size(35, 20)

$cmbTipoLog = New-Object System.Windows.Forms.ComboBox
$cmbTipoLog.Location = New-Object System.Drawing.Point(698, 43)
$cmbTipoLog.Size = New-Object System.Drawing.Size(140, 24)
$cmbTipoLog.DropDownStyle = "DropDown"
[void]$cmbTipoLog.Items.Add("(todos)")
[void]$cmbTipoLog.Items.Add("Inserindo")
[void]$cmbTipoLog.Items.Add("Editando")
[void]$cmbTipoLog.Items.Add("Fiscal")
[void]$cmbTipoLog.Items.Add("Receive")
[void]$cmbTipoLog.Items.Add("Geral")
[void]$cmbTipoLog.Items.Add("Transf. Prod")
$cmbTipoLog.SelectedIndex = 0

$chkSomenteErros = New-Object System.Windows.Forms.CheckBox
$chkSomenteErros.Text = "Somente erros"
$chkSomenteErros.Location = New-Object System.Drawing.Point(848, 45)
$chkSomenteErros.Size = New-Object System.Drawing.Size(115, 22)
$chkSomenteErros.ForeColor = [System.Drawing.Color]::DarkRed

$chkSomenteSucesso = New-Object System.Windows.Forms.CheckBox
$chkSomenteSucesso.Text = "Somente sucesso"
$chkSomenteSucesso.Location = New-Object System.Drawing.Point(968, 45)
$chkSomenteSucesso.Size = New-Object System.Drawing.Size(125, 22)
$chkSomenteSucesso.ForeColor = [System.Drawing.Color]::DarkGreen

$lblResumoLog = New-Object System.Windows.Forms.Label
$lblResumoLog.Location = New-Object System.Drawing.Point(1095, 47)
$lblResumoLog.Size = New-Object System.Drawing.Size(195, 20)
$lblResumoLog.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

# ----- Linha 3: BUSCA LIVRE (pesquisa em todas as colunas) -----
$lblBuscaLivre = New-Object System.Windows.Forms.Label
$lblBuscaLivre.Text = "Busca livre:"
$lblBuscaLivre.Location = New-Object System.Drawing.Point(10, 78)
$lblBuscaLivre.Size = New-Object System.Drawing.Size(75, 20)

$txtBuscaLivre = New-Object System.Windows.Forms.TextBox
$txtBuscaLivre.Location = New-Object System.Drawing.Point(90, 76)
$txtBuscaLivre.Size = New-Object System.Drawing.Size(400, 24)
$txtBuscaLivre.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)

$lblBuscaLivreHint = New-Object System.Windows.Forms.Label
$lblBuscaLivreHint.Text = "(pesquisa em usuario, computador, tipo, mesa, hora e descricao - inclui dentro do JSON)"
$lblBuscaLivreHint.Location = New-Object System.Drawing.Point(500, 79)
$lblBuscaLivreHint.Size = New-Object System.Drawing.Size(780, 20)
$lblBuscaLivreHint.ForeColor = [System.Drawing.Color]::DimGray
$lblBuscaLivreHint.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
$lblBuscaLivreHint.Anchor = "Top,Left,Right"

$gridSecoes = New-GridPadrao -X 10 -Y 110 -W 1280 -H 160
$gridSecoes.Anchor = "Top,Left,Right"

$lblRegistros = New-Object System.Windows.Forms.Label
$lblRegistros.Text = "Registros (duplo clique abre o JSON). Filtros aplicados em tempo real:"
$lblRegistros.Location = New-Object System.Drawing.Point(10, 275)
$lblRegistros.Size = New-Object System.Drawing.Size(700, 18)
$lblRegistros.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
$lblRegistros.ForeColor = [System.Drawing.Color]::DimGray

$gridRegistros = New-GridPadrao -X 10 -Y 295 -W 1280 -H 405

$tabLogSistema.Controls.Add($btnAbrirPdf)
$tabLogSistema.Controls.Add($btnConectarFirebird)
$tabLogSistema.Controls.Add($lblArquivo)
$tabLogSistema.Controls.Add($lblFiltroLog)
$tabLogSistema.Controls.Add($txtFiltroLog)
$tabLogSistema.Controls.Add($btnLimparFiltrosLog)
$tabLogSistema.Controls.Add($lblHoraDe)
$tabLogSistema.Controls.Add($txtHoraDe)
$tabLogSistema.Controls.Add($lblHoraAte)
$tabLogSistema.Controls.Add($txtHoraAte)
$tabLogSistema.Controls.Add($lblMesa)
$tabLogSistema.Controls.Add($txtMesa)
$tabLogSistema.Controls.Add($lblUsuarioLog)
$tabLogSistema.Controls.Add($txtUsuarioLog)
$tabLogSistema.Controls.Add($lblTipoLog)
$tabLogSistema.Controls.Add($cmbTipoLog)
$tabLogSistema.Controls.Add($chkSomenteErros)
$tabLogSistema.Controls.Add($chkSomenteSucesso)
$tabLogSistema.Controls.Add($lblResumoLog)
$tabLogSistema.Controls.Add($lblBuscaLivre)
$tabLogSistema.Controls.Add($txtBuscaLivre)
$tabLogSistema.Controls.Add($lblBuscaLivreHint)
$tabLogSistema.Controls.Add($gridSecoes)
$tabLogSistema.Controls.Add($lblRegistros)
$tabLogSistema.Controls.Add($gridRegistros)

$tabs.Controls.Add($tabDesligamentos)
$tabs.Controls.Add($tabCredenciais)
$tabs.Controls.Add($tabImpressoras)
$tabs.Controls.Add($tabLogSistema)
# ============================================================
#  ABA 5 - DIAGNOSTICO DE REDE (Windows nativo / sem instalacao)
# ============================================================
$tabRede = New-Object System.Windows.Forms.TabPage
$tabRede.Text = "Diagnostico de Rede"
$tabRede.BackColor = [System.Drawing.Color]::White

$lblRedeDestino = New-Object System.Windows.Forms.Label
$lblRedeDestino.Text = "IP para monitorar (roteador, servidor ou PDV):"
$lblRedeDestino.Location = New-Object System.Drawing.Point(14, 16)
$lblRedeDestino.Size = New-Object System.Drawing.Size(290, 22)

$txtRedeDestino = New-Object System.Windows.Forms.TextBox
$txtRedeDestino.Location = New-Object System.Drawing.Point(305, 13)
$txtRedeDestino.Size = New-Object System.Drawing.Size(150, 25)
$txtRedeDestino.Text = ""
$txtRedeDestino.Anchor = "Top,Left"

$btnRedeIniciar = New-Object System.Windows.Forms.Button
$btnRedeIniciar.Text = "Iniciar monitoramento"
$btnRedeIniciar.Location = New-Object System.Drawing.Point(470, 11)
$btnRedeIniciar.Size = New-Object System.Drawing.Size(150, 29)

$btnRedeParar = New-Object System.Windows.Forms.Button
$btnRedeParar.Text = "Parar"
$btnRedeParar.Location = New-Object System.Drawing.Point(628, 11)
$btnRedeParar.Size = New-Object System.Drawing.Size(80, 29)
$btnRedeParar.Enabled = $false

$btnRedeExportar = New-Object System.Windows.Forms.Button
$btnRedeExportar.Text = "Exportar CSV"
$btnRedeExportar.Location = New-Object System.Drawing.Point(716, 11)
$btnRedeExportar.Size = New-Object System.Drawing.Size(105, 29)

$lblRedeServidor = New-Object System.Windows.Forms.Label
$lblRedeServidor.Text = "Este computador: identificando..."
$lblRedeServidor.Location = New-Object System.Drawing.Point(14, 48)
$lblRedeServidor.Size = New-Object System.Drawing.Size(450, 22)

$lblRedeEstado = New-Object System.Windows.Forms.Label
$lblRedeEstado.Text = "Monitoramento parado"
$lblRedeEstado.Location = New-Object System.Drawing.Point(470, 48)
$lblRedeEstado.Size = New-Object System.Drawing.Size(450, 22)

$lblRedeResumo = New-Object System.Windows.Forms.Label
$lblRedeResumo.Text = "Aguardando teste. Intervalo: 2 segundos."
$lblRedeResumo.Location = New-Object System.Drawing.Point(14, 75)
$lblRedeResumo.Size = New-Object System.Drawing.Size(900, 22)

$gridRede = New-GridPadrao -X 14 -Y 105 -W 1190 -H 560
$gridRede.Anchor = "Top,Bottom,Left,Right"
[void]$gridRede.Columns.Add("Hora", "Horário")
[void]$gridRede.Columns.Add("Destino", "Destino")
[void]$gridRede.Columns.Add("IP", "IP")
[void]$gridRede.Columns.Add("Latencia", "Latência (ms)")
[void]$gridRede.Columns.Add("Status", "Resultado")
[void]$gridRede.Columns.Add("Perda", "Perda acumulada")
$gridRede.Columns["Hora"].Width = 150
$gridRede.Columns["Destino"].Width = 170
$gridRede.Columns["IP"].Width = 150
$gridRede.Columns["Latencia"].Width = 120
$gridRede.Columns["Status"].Width = 300
$gridRede.Columns["Perda"].Width = 140

foreach ($c in @($lblRedeDestino, $lblRedeServidor, $lblRedeEstado, $lblRedeResumo)) {
    $c.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
}
$tabRede.Controls.Add($lblRedeDestino)
$tabRede.Controls.Add($txtRedeDestino)
$tabRede.Controls.Add($btnRedeIniciar)
$tabRede.Controls.Add($btnRedeParar)
$tabRede.Controls.Add($btnRedeExportar)
$tabRede.Controls.Add($lblRedeServidor)
$tabRede.Controls.Add($lblRedeEstado)
$tabRede.Controls.Add($lblRedeResumo)
$tabRede.Controls.Add($gridRede)

# Adiciona a aba somente depois de criar o TabPage e seus controles.
$tabs.Controls.Add($tabRede)

# ============================================================
#  ABA 6 - REPARADOR DE CAMINHO E ADMINISTRACAO REMOTA
# ============================================================
$tabAdminRede = New-Object System.Windows.Forms.TabPage
$tabAdminRede.Text = "Reparador / Remoting"
$tabAdminRede.BackColor = [System.Drawing.Color]::White

$lblAdminTitulo = New-Object System.Windows.Forms.Label
$lblAdminTitulo.Text = "Reparar acesso ao servidor e administrar PowerShell Remoting"
$lblAdminTitulo.Location = New-Object System.Drawing.Point(16, 14)
$lblAdminTitulo.Size = New-Object System.Drawing.Size(850, 26)
$lblAdminTitulo.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 12, [System.Drawing.FontStyle]::Bold)

$lblSrvDestino = New-Object System.Windows.Forms.Label
$lblSrvDestino.Text = "Hostname/IP do servidor ou PC remoto:"
$lblSrvDestino.Location = New-Object System.Drawing.Point(16, 52)
$lblSrvDestino.Size = New-Object System.Drawing.Size(190, 22)
$txtSrvDestino = New-Object System.Windows.Forms.TextBox
$txtSrvDestino.Location = New-Object System.Drawing.Point(210, 49)
$txtSrvDestino.Size = New-Object System.Drawing.Size(230, 25)

$lblCompartilhamento = New-Object System.Windows.Forms.Label
$lblCompartilhamento.Text = "Compartilhamento:"
$lblCompartilhamento.Location = New-Object System.Drawing.Point(460, 52)
$lblCompartilhamento.Size = New-Object System.Drawing.Size(125, 22)
$txtCompartilhamento = New-Object System.Windows.Forms.TextBox
$txtCompartilhamento.Location = New-Object System.Drawing.Point(585, 49)
$txtCompartilhamento.Size = New-Object System.Drawing.Size(130, 25)
$txtCompartilhamento.Text = "data"
$btnResolverServidor = New-Object System.Windows.Forms.Button
$btnResolverServidor.Text = "Resolver nome"
$btnResolverServidor.Location = New-Object System.Drawing.Point(725, 47)
$btnResolverServidor.Size = New-Object System.Drawing.Size(125, 28)

$lblCaminhoUNC = New-Object System.Windows.Forms.Label
$lblCaminhoUNC.Text = "Caminho UNC: informe o servidor e o compartilhamento."
$lblCaminhoUNC.Location = New-Object System.Drawing.Point(16, 82)
$lblCaminhoUNC.Size = New-Object System.Drawing.Size(850, 22)

$btnTestarPasta = New-Object System.Windows.Forms.Button
$btnTestarPasta.Text = "Testar compartilhamento"
$btnTestarPasta.Location = New-Object System.Drawing.Point(16, 112)
$btnTestarPasta.Size = New-Object System.Drawing.Size(170, 32)
$btnAbrirPasta = New-Object System.Windows.Forms.Button
$btnAbrirPasta.Text = "Abrir pasta"
$btnAbrirPasta.Location = New-Object System.Drawing.Point(194, 112)
$btnAbrirPasta.Size = New-Object System.Drawing.Size(105, 32)
$btnCopiarUNC = New-Object System.Windows.Forms.Button
$btnCopiarUNC.Text = "Copiar caminho"
$btnCopiarUNC.Location = New-Object System.Drawing.Point(307, 112)
$btnCopiarUNC.Size = New-Object System.Drawing.Size(125, 32)
$btnConectarPasta = New-Object System.Windows.Forms.Button
$btnConectarPasta.Text = "Conectar com credenciais"
$btnConectarPasta.Location = New-Object System.Drawing.Point(440, 112)
$btnConectarPasta.Size = New-Object System.Drawing.Size(190, 32)
$lblUnidade = New-Object System.Windows.Forms.Label
$lblUnidade.Text = "Unidade:"
$lblUnidade.Location = New-Object System.Drawing.Point(646, 118)
$lblUnidade.Size = New-Object System.Drawing.Size(60, 22)
$txtUnidade = New-Object System.Windows.Forms.TextBox
$txtUnidade.Location = New-Object System.Drawing.Point(706, 115)
$txtUnidade.Size = New-Object System.Drawing.Size(45, 25)
$txtUnidade.Text = "Z:"

$sepAdmin = New-Object System.Windows.Forms.Label
$sepAdmin.BorderStyle = [System.Windows.Forms.BorderStyle]::Fixed3D
$sepAdmin.Location = New-Object System.Drawing.Point(16, 158)
$sepAdmin.Size = New-Object System.Drawing.Size(900, 2)

$lblRemotingTitulo = New-Object System.Windows.Forms.Label
$lblRemotingTitulo.Text = "PowerShell Remoting (WinRM)"
$lblRemotingTitulo.Location = New-Object System.Drawing.Point(16, 174)
$lblRemotingTitulo.Size = New-Object System.Drawing.Size(500, 24)
$lblRemotingTitulo.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10, [System.Drawing.FontStyle]::Bold)
$lblRemotingInfo = New-Object System.Windows.Forms.Label
$lblRemotingInfo.Text = "Para habilitar remotamente, o destino precisa aceitar um canal administrativo. Se WinRM estiver desligado, execute a preparacao no proprio destino ou use uma ferramenta administrativa ja autorizada."
$lblRemotingInfo.Location = New-Object System.Drawing.Point(16, 202)
$lblRemotingInfo.Size = New-Object System.Drawing.Size(900, 42)
$lblRemotingInfo.AutoSize = $false

$btnTestarWinRM = New-Object System.Windows.Forms.Button
$btnTestarWinRM.Text = "Testar WinRM remoto"
$btnTestarWinRM.Location = New-Object System.Drawing.Point(16, 252)
$btnTestarWinRM.Size = New-Object System.Drawing.Size(160, 32)
$btnPrepararRemoto = New-Object System.Windows.Forms.Button
$btnPrepararRemoto.Text = "Habilitar no destino"
$btnPrepararRemoto.Location = New-Object System.Drawing.Point(184, 252)
$btnPrepararRemoto.Size = New-Object System.Drawing.Size(155, 32)
$btnTrustedHost = New-Object System.Windows.Forms.Button
$btnTrustedHost.Text = "Confiar neste destino"
$btnTrustedHost.Location = New-Object System.Drawing.Point(347, 252)
$btnTrustedHost.Size = New-Object System.Drawing.Size(165, 32)
$btnPrepararLocal = New-Object System.Windows.Forms.Button
$btnPrepararLocal.Text = "Habilitar neste PC"
$btnPrepararLocal.Location = New-Object System.Drawing.Point(520, 252)
$btnPrepararLocal.Size = New-Object System.Drawing.Size(150, 32)
$btnCopiarPreparacao = New-Object System.Windows.Forms.Button
$btnCopiarPreparacao.Text = "Copiar comando de preparacao"
$btnCopiarPreparacao.Location = New-Object System.Drawing.Point(678, 252)
$btnCopiarPreparacao.Size = New-Object System.Drawing.Size(220, 32)

$lblAdminAcoes = New-Object System.Windows.Forms.Label
$lblAdminAcoes.Text = "Acoes remotas no computador selecionado"
$lblAdminAcoes.Location = New-Object System.Drawing.Point(16, 300)
$lblAdminAcoes.Size = New-Object System.Drawing.Size(500, 22)
$lblAdminAcoes.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 10, [System.Drawing.FontStyle]::Bold)
$btnDesligarRemoto = New-Object System.Windows.Forms.Button
$btnDesligarRemoto.Text = "Desligar PC"
$btnDesligarRemoto.Location = New-Object System.Drawing.Point(16, 326)
$btnDesligarRemoto.Size = New-Object System.Drawing.Size(130, 32)
$btnReiniciarRemoto = New-Object System.Windows.Forms.Button
$btnReiniciarRemoto.Text = "Reiniciar PC"
$btnReiniciarRemoto.Location = New-Object System.Drawing.Point(154, 326)
$btnReiniciarRemoto.Size = New-Object System.Drawing.Size(130, 32)
$btnRenovarIPRemoto = New-Object System.Windows.Forms.Button
$btnRenovarIPRemoto.Text = "Renovar IP"
$btnRenovarIPRemoto.Location = New-Object System.Drawing.Point(292, 326)
$btnRenovarIPRemoto.Size = New-Object System.Drawing.Size(130, 32)
$lblAdminAcoesInfo = New-Object System.Windows.Forms.Label
$lblAdminAcoesInfo.Text = "As acoes exigem WinRM ativo e uma conta autorizada. Renovar o IP pode interromper a sessao remota temporariamente."
$lblAdminAcoesInfo.Location = New-Object System.Drawing.Point(16, 363)
$lblAdminAcoesInfo.Size = New-Object System.Drawing.Size(900, 34)
$lblAdminAcoesInfo.AutoSize = $false

$lblAdminLog = New-Object System.Windows.Forms.Label
$lblAdminLog.Text = "Log de operacoes"
$lblAdminLog.Location = New-Object System.Drawing.Point(16, 402)
$lblAdminLog.Size = New-Object System.Drawing.Size(300, 22)
$txtAdminLog = New-Object System.Windows.Forms.TextBox
$txtAdminLog.Location = New-Object System.Drawing.Point(16, 426)
$txtAdminLog.Size = New-Object System.Drawing.Size(900, 218)
$txtAdminLog.Multiline = $true
$txtAdminLog.ReadOnly = $true
$txtAdminLog.ScrollBars = "Vertical"
$txtAdminLog.WordWrap = $false
$txtAdminLog.Anchor = "Top,Bottom,Left,Right"

foreach ($ctrl in @($lblAdminTitulo,$lblSrvDestino,$lblCompartilhamento,$lblCaminhoUNC,$lblUnidade,$lblRemotingTitulo,$lblRemotingInfo,$lblAdminAcoes,$lblAdminAcoesInfo,$lblAdminLog)) {
    $ctrl.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
}
foreach ($ctrl in @($btnResolverServidor,$btnTestarPasta,$btnAbrirPasta,$btnCopiarUNC,$btnConectarPasta,$btnTestarWinRM,$btnPrepararRemoto,$btnTrustedHost,$btnPrepararLocal,$btnCopiarPreparacao,$btnDesligarRemoto,$btnReiniciarRemoto,$btnRenovarIPRemoto)) {
    $ctrl.FlatStyle = "Flat"
}
$tabAdminRede.Controls.AddRange([System.Windows.Forms.Control[]]@(
    $lblAdminTitulo,$lblSrvDestino,$txtSrvDestino,$lblCompartilhamento,$txtCompartilhamento,$btnResolverServidor,$lblCaminhoUNC,
    $btnTestarPasta,$btnAbrirPasta,$btnCopiarUNC,$btnConectarPasta,$lblUnidade,$txtUnidade,$sepAdmin,
    $lblRemotingTitulo,$lblRemotingInfo,$btnTestarWinRM,$btnPrepararRemoto,$btnTrustedHost,$btnPrepararLocal,
    $btnCopiarPreparacao,$lblAdminAcoes,$btnDesligarRemoto,$btnReiniciarRemoto,$btnRenovarIPRemoto,$lblAdminAcoesInfo,$lblAdminLog,$txtAdminLog
))
$tabs.Controls.Add($tabAdminRede)

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
#  DASHBOARD VISUAL - MENU LATERAL E TEMA ESCURO
#  A navegacao usa as abas existentes, preservando a logica.
# ============================================================
$sidebar = New-Object System.Windows.Forms.Panel
$sidebar.Location = New-Object System.Drawing.Point(0, 0)
$sidebar.Size = New-Object System.Drawing.Size(215, 860)
$sidebar.Anchor = "Top,Bottom,Left"
$sidebar.BackColor = [System.Drawing.Color]::FromArgb(11, 18, 32)

$brand = New-Object System.Windows.Forms.Label
$brand.Text = "Central de logs"
$brand.Location = New-Object System.Drawing.Point(16, 22)
$brand.Size = New-Object System.Drawing.Size(185, 55)
$brand.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 14, [System.Drawing.FontStyle]::Bold)
$brand.ForeColor = [System.Drawing.Color]::FromArgb(96, 165, 250)
$sidebar.Controls.Add($brand)

$subBrand = New-Object System.Windows.Forms.Label
$subBrand.Text = "Dashboard"
$subBrand.Location = New-Object System.Drawing.Point(18, 78)
$subBrand.Size = New-Object System.Drawing.Size(185, 22)
$subBrand.Font = New-Object System.Drawing.Font("Segoe UI", 8)
$subBrand.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$sidebar.Controls.Add($subBrand)

$navTitle = New-Object System.Windows.Forms.Label
$navTitle.Text = "MENU"
$navTitle.Location = New-Object System.Drawing.Point(18, 130)
$navTitle.Size = New-Object System.Drawing.Size(170, 20)
$navTitle.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$navTitle.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$sidebar.Controls.Add($navTitle)

$navItems = @(
    @{ Text = "  Desligamentos"; Index = 0 },
    @{ Text = "  Credenciais de Rede"; Index = 1 },
    @{ Text = "  Impressoras"; Index = 2 },
    @{ Text = "  Log do Sistema / PDF"; Index = 3 },
    @{ Text = "  Diagnostico de Rede"; Index = 4 },
    @{ Text = "  Reparar / Remoting"; Index = 5 }
)
$navY = 162
foreach ($item in $navItems) {
    $navButton = New-Object System.Windows.Forms.Button
    $navButton.Text = $item.Text
    $navButton.Tag = $item.Index
    $navButton.Location = New-Object System.Drawing.Point(10, $navY)
    $navButton.Size = New-Object System.Drawing.Size(195, 42)
    $navButton.FlatStyle = "Flat"
    $navButton.FlatAppearance.BorderSize = 0
    $navButton.TextAlign = "MiddleLeft"
    $navButton.Padding = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
    $navButton.BackColor = [System.Drawing.Color]::FromArgb(20, 30, 49)
    $navButton.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
    $navButton.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
    $navButton.Cursor = [System.Windows.Forms.Cursors]::Hand
    $navButton.Add_Click({
        $tabs.SelectedIndex = [int]$this.Tag
        foreach ($control in $sidebar.Controls) {
            if ($control -is [System.Windows.Forms.Button]) {
                $control.BackColor = [System.Drawing.Color]::FromArgb(20, 30, 49)
                $control.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
            }
        }
        $this.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
        $this.ForeColor = [System.Drawing.Color]::White
    })
    $sidebar.Controls.Add($navButton)
    $navY += 50
}

$sidebar.Controls.Add($navTitle)
$form.Controls.Add($sidebar)
$sidebar.SendToBack()

# Barra superior do dashboard
$header = New-Object System.Windows.Forms.Panel
$header.Location = New-Object System.Drawing.Point(230, 12)
$header.Size = New-Object System.Drawing.Size(1240, 100)
$header.Anchor = "Top,Left,Right"
$header.BackColor = [System.Drawing.Color]::FromArgb(20, 30, 49)

$headerTitle = New-Object System.Windows.Forms.Label
$headerTitle.Text = "Painel de monitoramento"
$headerTitle.Location = New-Object System.Drawing.Point(18, 8)
$headerTitle.Size = New-Object System.Drawing.Size(360, 30)
$headerTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 16, [System.Drawing.FontStyle]::Bold)
$headerTitle.ForeColor = [System.Drawing.Color]::White
$header.Controls.Add($headerTitle)

$headerHint = New-Object System.Windows.Forms.Label
$headerHint.Text = "Logs de eventos do sistema."
$headerHint.Location = New-Object System.Drawing.Point(20, 43)
$headerHint.Size = New-Object System.Drawing.Size(700, 24)
$headerHint.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$headerHint.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$header.Controls.Add($headerHint)
$form.Controls.Add($header)
# Os controles de periodo/atualizacao ficam dentro da barra superior.
foreach ($topControl in @($lblPeriodo, $numDias, $btnAtualizarTudo, $btnLimparAlertas, $lblIntervalo, $numIntervalo, $chkAuto)) {
    [void]$form.Controls.Remove($topControl)
    $header.Controls.Add($topControl)
}
$lblPeriodo.Location = New-Object System.Drawing.Point(18, 70)
$numDias.Location = New-Object System.Drawing.Point(108, 67)
$btnAtualizarTudo.Location = New-Object System.Drawing.Point(178, 66)
$btnLimparAlertas.Location = New-Object System.Drawing.Point(273, 66)
$lblIntervalo.Location = New-Object System.Drawing.Point(405, 70)
$numIntervalo.Location = New-Object System.Drawing.Point(475, 67)
$chkAuto.Location = New-Object System.Drawing.Point(540, 69)
$header.BringToFront()

# Tema escuro consistente para abas, campos e tabelas
$darkBack = [System.Drawing.Color]::FromArgb(15, 23, 42)
$panelBack = [System.Drawing.Color]::FromArgb(20, 30, 49)
$textColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
$mutedColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
$accentColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
foreach ($page in @($tabDesligamentos, $tabCredenciais, $tabImpressoras, $tabLogSistema, $tabRede, $tabAdminRede)) {
    $page.BackColor = $darkBack
    $page.ForeColor = $textColor
}
foreach ($grid in @($gridDesl, $gridCred, $gridImp, $gridSecoes, $gridRegistros, $gridRede)) {
    if ($null -ne $grid) {
        $grid.BackgroundColor = $panelBack
        $grid.BorderStyle = "None"
        $grid.EnableHeadersVisualStyles = $false
        $grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
        $grid.ColumnHeadersDefaultCellStyle.ForeColor = $textColor
        $grid.DefaultCellStyle.BackColor = $panelBack
        $grid.DefaultCellStyle.ForeColor = $textColor
        $grid.DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(30, 64, 115)
        $grid.DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
        $grid.GridColor = [System.Drawing.Color]::FromArgb(45, 58, 78)
        $grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(24, 36, 56)
        $grid.RowHeadersVisible = $false
    }
}
foreach ($page in @($tabDesligamentos, $tabCredenciais, $tabImpressoras, $tabLogSistema, $tabRede, $tabAdminRede)) {
    foreach ($control in $page.Controls) {
        if ($control -is [System.Windows.Forms.Label]) {
            $control.ForeColor = $textColor
            if ($control.Font.Size -lt 9) { $control.ForeColor = $mutedColor }
        } elseif ($control -is [System.Windows.Forms.TextBox]) {
            $control.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
            $control.ForeColor = $textColor
            $control.BorderStyle = "FixedSingle"
        } elseif ($control -is [System.Windows.Forms.ComboBox]) {
            $control.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
            $control.ForeColor = $textColor
            $control.FlatStyle = "Flat"
        } elseif ($control -is [System.Windows.Forms.CheckBox]) {
            $control.ForeColor = $textColor
        } elseif ($control -is [System.Windows.Forms.Button]) {
            $control.FlatStyle = "Flat"
            $control.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(59, 130, 246)
            $control.BackColor = $accentColor
            $control.ForeColor = [System.Drawing.Color]::White
            $control.Cursor = [System.Windows.Forms.Cursors]::Hand
        }
    }
}
foreach ($control in @($lblPeriodo, $lblIntervalo, $chkAuto)) {
    $control.ForeColor = $textColor
}
foreach ($control in @($numDias, $numIntervalo)) {
    $control.BackColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
    $control.ForeColor = $textColor
}
$status.BackColor = [System.Drawing.Color]::FromArgb(11, 18, 32)
$status.ForeColor = $mutedColor
$statusLabel.ForeColor = $mutedColor

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
$script:DadosLogFiltrados = @()
$script:SecaoSelecionada = ""
$script:UltimoErroPdf = ""
$script:TextoBrutoPdf = ""

# Cores fortes para os eventos: fundos escuros e texto claro para alto contraste.
$script:Cores = @{
    41   = [System.Drawing.Color]::FromArgb(127, 29, 29)   # vermelho escuro - Kernel-Power
    6008 = [System.Drawing.Color]::FromArgb(120, 53, 15)   # amarelo/ambar escuro - desligamento inesperado
    1001 = [System.Drawing.Color]::FromArgb(88, 28, 135)  # roxo escuro - BSOD
    1074 = [System.Drawing.Color]::FromArgb(20, 83, 45)   # verde escuro - desligamento planejado
    4625 = [System.Drawing.Color]::FromArgb(127, 29, 29)  # vermelho escuro - falha de logon
    4776 = [System.Drawing.Color]::FromArgb(120, 53, 15)  # ambar escuro - validacao de credenciais
    4740 = [System.Drawing.Color]::FromArgb(88, 28, 135)  # roxo escuro - conta bloqueada
    6161 = [System.Drawing.Color]::FromArgb(127, 29, 29)  # vermelho escuro - falha de impressora
    808  = [System.Drawing.Color]::FromArgb(120, 53, 15)  # ambar escuro - erro de impressao
    307  = [System.Drawing.Color]::FromArgb(20, 83, 45)   # verde escuro - trabalho enviado
}

$script:CoresTexto = @{
    41   = [System.Drawing.Color]::FromArgb(254, 202, 202)
    6008 = [System.Drawing.Color]::FromArgb(253, 230, 138)
    1001 = [System.Drawing.Color]::FromArgb(233, 213, 255)
    1074 = [System.Drawing.Color]::FromArgb(187, 247, 208)
    4625 = [System.Drawing.Color]::FromArgb(254, 202, 202)
    4776 = [System.Drawing.Color]::FromArgb(253, 230, 138)
    4740 = [System.Drawing.Color]::FromArgb(233, 213, 255)
    6161 = [System.Drawing.Color]::FromArgb(254, 202, 202)
    808  = [System.Drawing.Color]::FromArgb(253, 230, 138)
    307  = [System.Drawing.Color]::FromArgb(187, 247, 208)
}

$script:TipoDesl = @{41="Kernel-Power";6008="Desligamento Inesperado";1001="BSOD";1074="Desligamento Planejado"}
$script:TipoCred = @{4625="Falha de Logon";4776="Validacao de Credenciais";4740="Conta Bloqueada"}
$script:TipoImp = @{307="Trabalho Enviado";6161="Falha de Comunicacao";808="Erro de Impressao"}

# ============================================================
#  TIMER (precisa existir antes dos handlers que o referenciam)
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
#  CARREGADORES - DESLIGAMENTOS
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

# ============================================================
#  CARREGADORES - CREDENCIAIS
# ============================================================
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

# ============================================================
#  CARREGADORES - IMPRESSORAS
# ============================================================
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
        # Coluna de acao por linha, disponivel somente no modo Status atual (fila).
        if ($cmbModoImp.SelectedIndex -eq 1) {
            if (-not $gridImp.Columns.Contains("Teste")) {
                $colTeste = New-Object System.Windows.Forms.DataGridViewButtonColumn
                $colTeste.Name = "Teste"
                $colTeste.HeaderText = "Teste"
                $colTeste.Text = "Imprimir teste"
                $colTeste.UseColumnTextForButtonValue = $true
                $colTeste.Width = 105
                $colTeste.MinimumWidth = 95
                $colTeste.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
                [void]$gridImp.Columns.Add($colTeste)
            }
            $gridImp.Columns["Teste"].Visible = $true
            $gridImp.Columns["Teste"].DisplayIndex = $gridImp.Columns.Count - 1
        } elseif ($gridImp.Columns.Contains("Teste")) {
            $gridImp.Columns["Teste"].Visible = $false
        }
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

# Exportar nome, porta e driver das impressoras para TXT na Area de Trabalho
$btnSalvarListaImp.Add_Click({
    if ($cmbModoImp.SelectedIndex -ne 1) {
        [System.Windows.Forms.MessageBox]::Show("Selecione 'Status atual (fila)' para exportar nome, porta e driver.", "Lista de impressoras", "OK", "Information") | Out-Null
        return
    }
    $lista = @($script:DadosImpFiltrados)
    if ($lista.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Nao ha impressoras para salvar. Atualize a lista ou ajuste a busca.", "Lista de impressoras", "OK", "Warning") | Out-Null
        return
    }
    $desktop = [Environment]::GetFolderPath('Desktop')
    $arquivo = Join-Path $desktop ("Lista_Impressoras_{0}.txt" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    $linhas = @("LISTA DE IMPRESSORAS", "Gerado em: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')", "", ("{0}`t{1}`t{2}" -f 'Nome','Porta','Driver'))
    foreach ($imp in $lista) {
        $linhas += ("{0}`t{1}`t{2}" -f $imp.Nome, $imp.Porta, $imp.Driver)
    }
    try {
        [System.IO.File]::WriteAllLines($arquivo, $linhas, [System.Text.Encoding]::UTF8)
        $statusLabel.Text = "Lista de impressoras salva na Area de Trabalho."
        [System.Windows.Forms.MessageBox]::Show("Lista salva com sucesso:`r`n$arquivo", "Lista de impressoras", "OK", "Information") | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel salvar o arquivo:`r`n$($_.Exception.Message)", "Lista de impressoras", "OK", "Error") | Out-Null
    }
})

function Copiar-ListaImpressoras {
    if ($cmbModoImp.SelectedIndex -ne 1) {
        [System.Windows.Forms.MessageBox]::Show("Selecione 'Status atual (fila)' para copiar nome, porta e driver.", "Lista de impressoras", "OK", "Information") | Out-Null
        return
    }
    $linhas = @(("{0}`t{1}`t{2}" -f 'Nome','Porta','Driver'))
    foreach ($imp in @($script:DadosImpFiltrados)) {
        $linhas += ("{0}`t{1}`t{2}" -f $imp.Nome, $imp.Porta, $imp.Driver)
    }
    if ($linhas.Count -le 1) { return }
    try {
        [System.Windows.Forms.Clipboard]::SetText(($linhas -join "`r`n"))
        $statusLabel.Text = "Lista de impressoras copiada. Pode colar com Ctrl+V."
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel copiar a lista para a area de transferencia.", "Lista de impressoras", "OK", "Warning") | Out-Null
    }
}

$btnCopiarListaImp.Add_Click({ Copiar-ListaImpressoras })

$btnTesteComandaImp.Add_Click({
    if ($cmbModoImp.SelectedIndex -ne 1) {
        [System.Windows.Forms.MessageBox]::Show("Selecione 'Status atual (fila)' para enviar o teste à impressora.", "Teste de comanda", "OK", "Information") | Out-Null
        return
    }
    if (-not $gridImp.CurrentRow -or $gridImp.CurrentRow.Index -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Selecione uma impressora na lista primeiro.", "Teste de comanda", "OK", "Information") | Out-Null
        return
    }
    $selecionada = $null
    try { $selecionada = $gridImp.CurrentRow.DataBoundItem } catch {}
    if (-not $selecionada -or [string]::IsNullOrWhiteSpace([string]$selecionada.Nome)) {
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel identificar a impressora selecionada.", "Teste de comanda", "OK", "Warning") | Out-Null
        return
    }

    $confirmacao = [System.Windows.Forms.MessageBox]::Show(
        "Enviar uma comanda de teste para:`r`n$($selecionada.Nome)?`r`n`r`nO teste sera impresso imediatamente.",
        "Confirmar impressao", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($confirmacao -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $printDoc = New-Object System.Drawing.Printing.PrintDocument
    $printDoc.DocumentName = "Teste individual de comanda"
    $printDoc.PrinterSettings.PrinterName = [string]$selecionada.Nome
    if (-not $printDoc.PrinterSettings.IsValid) {
        $printDoc.Dispose()
        [System.Windows.Forms.MessageBox]::Show("A impressora selecionada nao esta disponivel no Windows: $($selecionada.Nome)", "Teste de comanda", "OK", "Error") | Out-Null
        return
    }
    $printDoc.DefaultPageSettings.Landscape = $false
    $printDoc.DefaultPageSettings.Margins = New-Object System.Drawing.Printing.Margins(5, 5, 5, 5)

    $printerNameForTicket = [string]$selecionada.Nome
    $hostNameForTicket = [string]$env:COMPUTERNAME
    $ipForTicket = "IP nao identificado"
    try {
        $ipLocal = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop |
            Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254*' -and $_.AddressState -eq 'Preferred' } |
            Sort-Object { if ($_.InterfaceAlias -match 'Wi-Fi|Ethernet|Rede') { 0 } else { 1 } } |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($ipLocal) { $ipForTicket = [string]$ipLocal }
    } catch {
        try {
            $ipLocal = [System.Net.Dns]::GetHostEntry($hostNameForTicket).AddressList |
                Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and $_.IPAddressToString -ne '127.0.0.1' } |
                Select-Object -First 1
            if ($ipLocal) { $ipForTicket = $ipLocal.IPAddressToString }
        } catch {}
    }
    $printHandler = {
        param($sender, $e)
        $g = $e.Graphics
        $g.PageUnit = [System.Drawing.GraphicsUnit]::Display
        $left = [single]$e.MarginBounds.Left
        $top = [single]$e.MarginBounds.Top
        $width = [single]$e.MarginBounds.Width
        $black = [System.Drawing.Brushes]::Black
        $white = [System.Drawing.Brushes]::White
        $fontTitle = New-Object System.Drawing.Font("Arial", 13, [System.Drawing.FontStyle]::Bold)
        $fontBanner = New-Object System.Drawing.Font("Arial", 20, [System.Drawing.FontStyle]::Bold)
        $font = New-Object System.Drawing.Font("Arial", 9, [System.Drawing.FontStyle]::Regular)
        $fontBold = New-Object System.Drawing.Font("Arial", 12, [System.Drawing.FontStyle]::Bold)
        $fontFooter = New-Object System.Drawing.Font("Arial", 8, [System.Drawing.FontStyle]::Bold)
        $y = $top
        $agora = Get-Date
        $hora = $agora.ToString("HH:mm")
        $dataHora = $agora.ToString("dd/MM HH:mm")

        # Cabecalho inspirado no cupom original, sem nome do estabelecimento/copia.
        $cabecalho = "TESTE DE IMPRESSAO"
        $cabSize = $g.MeasureString($cabecalho, $fontTitle)
        $g.DrawString($cabecalho, $fontTitle, $black, $left + [Math]::Max(0, ($width - $cabSize.Width) / 2), $y)
        $y += 27

        # Tarja preta: somente o identificador solicitado.
        $g.FillRectangle($black, $left + 8, $y, $width - 16, 42)
        $bannerText = "#999"
        $bannerSize = $g.MeasureString($bannerText, $fontBanner)
        $g.DrawString($bannerText, $fontBanner, $white, $left + ($width - $bannerSize.Width) / 2, $y + 4)
        $y += 72

        # Cabecalho da linha de itens com quantidade, descricao e horario.
        $g.DrawLine([System.Drawing.Pens]::Black, $left, $y, $left + $width, $y)
        $g.DrawString("Qtd", $fontBold, $black, $left + 12, $y + 3)
        $g.DrawString("Descricao", $fontBold, $black, $left + 58, $y + 3)
        $horaSize = $g.MeasureString($hora, $fontBold)
        $g.DrawString($hora, $fontBold, $black, $left + $width - $horaSize.Width - 16, $y + 3)
        $y += 28
        $g.DrawLine([System.Drawing.Pens]::Black, $left + 8, $y, $left + $width - 8, $y)
        $y += 22

        # Item de teste fixo solicitado.
        $g.DrawString("1", $fontBold, $black, $left + 25, $y)
        $descricao = "TESTE BITBAR NAO FAZER"
        $g.DrawString($descricao, $fontBold, $black, $left + 58, $y)
        $y += 48
        $g.DrawLine([System.Drawing.Pens]::Black, $left, $y, $left + $width, $y)
        $y += 10

        # Rodape sem versao e sem superusuario; inclui hostname, IP, data/hora e impressora.
        $g.DrawString(("PC: {0}  IP: {1}" -f $hostNameForTicket, $ipForTicket), $fontFooter, $black, $left + 12, $y)
        $dataSize = $g.MeasureString($dataHora, $fontFooter)
        $g.DrawString($dataHora, $fontFooter, $black, $left + $width - $dataSize.Width - 12, $y)
        $y += 24
        $g.DrawString("#999", $fontFooter, $black, $left + 12, $y)
        $printerSize = $g.MeasureString($printerNameForTicket, $fontFooter)
        $g.DrawString($printerNameForTicket, $fontFooter, $black, $left + $width - $printerSize.Width - 12, $y)

        $fontTitle.Dispose(); $fontBanner.Dispose(); $font.Dispose(); $fontBold.Dispose(); $fontFooter.Dispose()
        $e.HasMorePages = $false
    }.GetNewClosure()
    $printDoc.add_PrintPage($printHandler)
    try {
        $printDoc.Print()
        $statusLabel.Text = "Comanda de teste enviada para: $($selecionada.Nome)"
        [System.Windows.Forms.MessageBox]::Show("Comanda de teste enviada para a fila da impressora:`r`n$($selecionada.Nome)", "Teste enviado", "OK", "Information") | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Falha ao enviar o teste para a impressora:`r`n$($_.Exception.Message)", "Erro de impressao", "OK", "Error") | Out-Null
    } finally {
        $printDoc.Dispose()
    }
})

# Clique no botao da coluna Teste: seleciona a linha correspondente e reutiliza
# a mesma rotina de impressao do botao principal.
$gridImp.Add_CellContentClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    if ($sender.Columns[$e.ColumnIndex].Name -ne "Teste") { return }
    if ($cmbModoImp.SelectedIndex -ne 1) { return }
    try {
        $linha = $sender.Rows[$e.RowIndex]
        $colunaAlvo = $linha.Cells | Where-Object { $_.Visible -and $_.OwningColumn.Name -ne "Teste" } | Select-Object -First 1
        if ($colunaAlvo) { $sender.CurrentCell = $colunaAlvo }
        $sender.Rows[$e.RowIndex].Selected = $true
        $btnTesteComandaImp.PerformClick()
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel iniciar o teste desta impressora.`r`n$($_.Exception.Message)", "Teste de impressora", "OK", "Warning") | Out-Null
    }
})

$btnAbrirWebImp.Add_Click({
    if ($cmbModoImp.SelectedIndex -ne 1) {
        [System.Windows.Forms.MessageBox]::Show("Selecione 'Status atual (fila)' para abrir a pagina web da impressora.", "Pagina web da impressora", "OK", "Information") | Out-Null
        return
    }
    if (-not $gridImp.CurrentRow -or $gridImp.CurrentRow.Index -lt 0) {
        [System.Windows.Forms.MessageBox]::Show("Selecione uma impressora na lista primeiro.", "Pagina web da impressora", "OK", "Information") | Out-Null
        return
    }
    $selecionada = $null
    try { $selecionada = $gridImp.CurrentRow.DataBoundItem } catch {}
    if (-not $selecionada -or [string]::IsNullOrWhiteSpace([string]$selecionada.Porta)) {
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel identificar a porta da impressora selecionada.", "Pagina web da impressora", "OK", "Warning") | Out-Null
        return
    }

    $portaNome = [string]$selecionada.Porta
    $hostImpressora = $null
    # Portas Standard TCP/IP guardam o IP ou nome do equipamento.
    try {
        $portaObj = Get-PrinterPort -Name $portaNome -ErrorAction Stop
        if ($portaObj.PrinterHostAddress) { $hostImpressora = [string]$portaObj.PrinterHostAddress }
        elseif ($portaObj.HostAddress) { $hostImpressora = [string]$portaObj.HostAddress }
    } catch {}

    # Algumas instalacoes ja usam o IP/host como nome da porta.
    if ([string]::IsNullOrWhiteSpace($hostImpressora)) {
        if ($portaNome -match '^\\?([a-zA-Z0-9.-]+)$') { $hostImpressora = $Matches[1] }
        elseif ($portaNome -match '^IP_([a-zA-Z0-9.-]+)$') { $hostImpressora = $Matches[1] }
        elseif ($portaNome -match '^([0-9]{1,3}(?:\.[0-9]{1,3}){3})$') { $hostImpressora = $portaNome }
    }

    if ([string]::IsNullOrWhiteSpace($hostImpressora)) {
        [System.Windows.Forms.MessageBox]::Show("Nao consegui descobrir o IP/nome do equipamento pela porta '$portaNome'. Verifique se a impressora usa uma porta Standard TCP/IP.", "Pagina web da impressora", "OK", "Warning") | Out-Null
        return
    }

    # Evita aceitar valores que possam formar uma URL arbitraria.
    $hostImpressora = $hostImpressora.Trim()
    if ($hostImpressora -notmatch '^[a-zA-Z0-9.-]+$') {
        [System.Windows.Forms.MessageBox]::Show("O IP/nome detectado nao parece valido: $hostImpressora", "Pagina web da impressora", "OK", "Warning") | Out-Null
        return
    }
    $url = "http://$hostImpressora/"
    try {
        Start-Process $url
        $statusLabel.Text = "Abrindo pagina web de $($selecionada.Nome): $url"
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel abrir a pagina web:`r`n$url`r`n$($_.Exception.Message)", "Pagina web da impressora", "OK", "Error") | Out-Null
    }
})

$gridImp.Add_KeyDown({
    if ($_.Control -and $_.KeyCode -eq [System.Windows.Forms.Keys]::C) {
        $_.Handled = $true
        Copiar-ListaImpressoras
    }
})

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
}

function Atualizar-GridRegistros {
    param([string]$Secao)

    $dados = $script:LogRegistros
    if (-not [string]::IsNullOrWhiteSpace($Secao) -and $Secao -ne "(todas)") {
        $dados = $dados | Where-Object { $_.Secao -eq $Secao }
    }

    # ---- BUSCA LIVRE (procura em todas as colunas e no JSON raw) ----
    $buscaLivre = $txtBuscaLivre.Text.Trim()
    if ($buscaLivre -ne "") {
        $termo = $buscaLivre
        $dados = $dados | Where-Object {
            ($_.Usuario      -like "*$termo*") -or
            ($_.Computador   -like "*$termo*") -or
            ($_.Tipo         -like "*$termo*") -or
            ($_.MesaComanda  -like "*$termo*") -or
            ($_.Hora         -like "*$termo*") -or
            ($_.Descricao    -like "*$termo*") -or
            ($_.DescricaoRaw -like "*$termo*") -or
            ($_.Arquivo -like "*$termo*") -or
            ($_.Modificados -like "*$termo*") -or
            ($_.Codigo -like "*$termo*") -or
            ($_.Historico -like "*$termo*")
        }
    }

    $hDe  = $txtHoraDe.Text.Trim()
    $hAte = $txtHoraAte.Text.Trim()
    if ($hDe -match '^\d{1,2}:\d{2}') {
        $hDe = $hDe.PadLeft(5,'0')
        $dados = $dados | Where-Object { $_.Hora.Substring(0,5) -ge $hDe }
    }
    if ($hAte -match '^\d{1,2}:\d{2}') {
        $hAte = $hAte.PadLeft(5,'0')
        $dados = $dados | Where-Object { $_.Hora.Substring(0,5) -le $hAte }
    }

    $mesa = $txtMesa.Text.Trim()
    if ($mesa -ne "") {
        $dados = $dados | Where-Object {
            $_.MesaComanda -match [regex]::Escape($mesa) -or
            $_.Descricao   -match [regex]::Escape($mesa) -or
            $_.DescricaoRaw -match [regex]::Escape($mesa)
        }
    }

    $user = $txtUsuarioLog.Text.Trim()
    if ($user -ne "") {
        $dados = $dados | Where-Object { $_.Usuario -like "*$user*" }
    }

    if ($cmbTipoLog.SelectedIndex -gt 0) {
        $tipoSel = "$($cmbTipoLog.SelectedItem)"
        $dados = $dados | Where-Object { $_.Tipo -eq $tipoSel }
    }

    if ($chkSomenteErros.Checked) {
        $dados = $dados | Where-Object { Test-ErroLog $_.DescricaoRaw }
    }
    elseif ($chkSomenteSucesso.Checked) {
        $dados = $dados | Where-Object { Test-SucessoLog $_.DescricaoRaw }
    }

    $script:DadosLogFiltrados = @($dados)

    $gridRegistros.DataSource = $null
    if ($script:DadosLogFiltrados.Count -gt 0) {
        $bl = New-Object System.ComponentModel.BindingList[object]
        foreach ($i in $script:DadosLogFiltrados) { $bl.Add($i) | Out-Null }
        $gridRegistros.DataSource = $bl

        if ($gridRegistros.Columns.Count -gt 0) {
            $gridRegistros.Columns["Secao"].Visible = $false
            $gridRegistros.Columns["Data"].Visible = $false
            if ($gridRegistros.Columns.Contains("DescricaoRaw")) { $gridRegistros.Columns["DescricaoRaw"].Visible = $false }
            if ($gridRegistros.Columns.Contains("Payload"))     { $gridRegistros.Columns["Payload"].Visible = $false }
            $gridRegistros.Columns["Hora"].FillWeight = 10
            $gridRegistros.Columns["Usuario"].FillWeight = 10
            $gridRegistros.Columns["Computador"].FillWeight = 12
            $gridRegistros.Columns["Tipo"].FillWeight = 10
            if ($gridRegistros.Columns.Contains("MesaComanda")) {
                $gridRegistros.Columns["MesaComanda"].FillWeight = 10
                $gridRegistros.Columns["MesaComanda"].HeaderText = "Mesa/Comanda"
            }
            $gridRegistros.Columns["Descricao"].FillWeight = 48
        }
    }

    $qErros = @($script:DadosLogFiltrados | Where-Object { Test-ErroLog   $_.DescricaoRaw }).Count
    $qOk    = @($script:DadosLogFiltrados | Where-Object { Test-SucessoLog $_.DescricaoRaw }).Count
    $lblResumoLog.Text = "Total: $($script:DadosLogFiltrados.Count) | Erros: $qErros | OK: $qOk"
    $statusLabel.Text = "Registros: $($script:DadosLogFiltrados.Count)"
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
        if ($script:CoresTexto.ContainsKey($id)) { $e.CellStyle.ForeColor = $script:CoresTexto[$id] }
        $e.CellStyle.SelectionForeColor = [System.Drawing.Color]::White
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
        if ($script:CoresTexto.ContainsKey($id)) { $e.CellStyle.ForeColor = $script:CoresTexto[$id] }
        $e.CellStyle.SelectionForeColor = [System.Drawing.Color]::White
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
            if ($script:CoresTexto.ContainsKey($id)) { $e.CellStyle.ForeColor = $script:CoresTexto[$id] }
            $e.CellStyle.SelectionForeColor = [System.Drawing.Color]::White
            $e.CellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(
                [Math]::Max(0,$script:Cores[$id].R-40),
                [Math]::Max(0,$script:Cores[$id].G-40),
                [Math]::Max(0,$script:Cores[$id].B-40))
        }
    } else {
        $st = $r.Cells["Status"].Value
        $er = $r.Cells["JobsComErro"].Value
        if ($er -and [int]$er -gt 0) {
            $e.CellStyle.BackColor = [System.Drawing.Color]::FromArgb(127, 29, 29)
            $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(254, 202, 202)
        }
        elseif ($st -and $st -ne "Normal") {
            $e.CellStyle.BackColor = [System.Drawing.Color]::FromArgb(120, 53, 15)
            $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(253, 230, 138)
        }
        else {
            $e.CellStyle.BackColor = [System.Drawing.Color]::FromArgb(20, 83, 45)
            $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(187, 247, 208)
        }
        $e.CellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(30, 64, 115)
        $e.CellStyle.SelectionForeColor = [System.Drawing.Color]::White
    }
})

$gridRegistros.add_CellFormatting({
    param($s,$e)
    if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
    $r = $gridRegistros.Rows[$e.RowIndex]
    if ($r.Cells.Count -eq 0) { return }

    $desc = $r.Cells["Descricao"].Value
    $tipo = $r.Cells["Tipo"].Value
    $descStr = if ($null -ne $desc) { "$desc" } else { "" }
    $tipoStr = if ($null -ne $tipo) { "$tipo" } else { "" }
    $textoLog = "$tipoStr $descStr"

    # Mantem a prioridade das cores existentes: erro vermelho e sucesso verde.
    if (Test-ErroLog $descStr) {
        $e.CellStyle.BackColor = [System.Drawing.Color]::FromArgb(127, 29, 29)
        $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(254, 202, 202)
        $e.CellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(153, 27, 27)
        $e.CellStyle.SelectionForeColor = [System.Drawing.Color]::White
    }
    elseif (Test-SucessoLog $descStr) {
        $e.CellStyle.BackColor = [System.Drawing.Color]::FromArgb(20, 83, 45)
        $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(187, 247, 208)
        $e.CellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(22, 101, 52)
        $e.CellStyle.SelectionForeColor = [System.Drawing.Color]::White
    }
    # Roxo: exclusoes/remocoes. Verifica o tipo e o texto da descricao.
    elseif ($textoLog -match '(?i)exclu[íi]d|exclus[aã]o|deletad|delete|removid|remo[cç][aã]o|apagado|apagar|del') {
        $e.CellStyle.BackColor = [System.Drawing.Color]::FromArgb(76, 29, 149)
        $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(237, 233, 254)
        $e.CellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(91, 33, 182)
        $e.CellStyle.SelectionForeColor = [System.Drawing.Color]::White
    }
    # Amarelo: registros do tipo Editando ou descricoes que indiquem alteracao.
    elseif ($tipoStr -match '(?i)^Editando$' -or $textoLog -match '(?i)editad|edi[cç][aã]o|altera[cç][aã]o|alterado|atualizad|modificad') {
        $e.CellStyle.BackColor = [System.Drawing.Color]::FromArgb(254, 240, 138)
        $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(113, 63, 18)
        $e.CellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(234, 179, 8)
        $e.CellStyle.SelectionForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
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

# --- Consulta direta ao Firebird ---
# Dados de conexão mantidos somente na memória durante esta execução.
# A senha nunca é gravada no MonitorConfig.json nem em outro arquivo de configuração.
if (-not (Get-Variable -Name FirebirdSessao -Scope Script -ErrorAction SilentlyContinue)) {
    $script:FirebirdSessao = $null
}

function Mostrar-DialogoFirebird {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = 'Configuração da conexão Firebird'
    $dlg.Size = New-Object System.Drawing.Size(590, 465)
    $dlg.StartPosition = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.ShowInTaskbar = $false

    $titulo = New-Object System.Windows.Forms.Label
    $titulo.Text = 'Configurações de conexão Firebird'
    $titulo.Font = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $titulo.Location = New-Object System.Drawing.Point(18, 15)
    $titulo.Size = New-Object System.Drawing.Size(520, 25)
    $dlg.Controls.Add($titulo)

    $lblHost = New-Object System.Windows.Forms.Label
    $lblHost.Text = 'Host / IP:'
    $lblHost.Location = New-Object System.Drawing.Point(22, 60)
    $lblHost.Size = New-Object System.Drawing.Size(100, 22)
    $txtHost = New-Object System.Windows.Forms.TextBox
    $txtHost.Location = New-Object System.Drawing.Point(130, 57)
    $txtHost.Size = New-Object System.Drawing.Size(270, 24)
    $txtHost.Text = if ($script:FirebirdSessao) { $script:FirebirdSessao.Servidor } else { 'localhost' }

    $lblPorta = New-Object System.Windows.Forms.Label
    $lblPorta.Text = 'Porta:'
    $lblPorta.Location = New-Object System.Drawing.Point(415, 60)
    $lblPorta.Size = New-Object System.Drawing.Size(45, 22)
    $txtPorta = New-Object System.Windows.Forms.TextBox
    $txtPorta.Location = New-Object System.Drawing.Point(460, 57)
    $txtPorta.Size = New-Object System.Drawing.Size(85, 24)
    $txtPorta.Text = if ($script:FirebirdSessao) { $script:FirebirdSessao.Porta } else { '3050' }

    $lblBanco = New-Object System.Windows.Forms.Label
    $lblBanco.Text = 'Banco / caminho:'
    $lblBanco.Location = New-Object System.Drawing.Point(22, 105)
    $lblBanco.Size = New-Object System.Drawing.Size(105, 22)
    $txtBanco = New-Object System.Windows.Forms.TextBox
    $txtBanco.Location = New-Object System.Drawing.Point(130, 102)
    $txtBanco.Size = New-Object System.Drawing.Size(415, 24)
    $txtBanco.Text = if ($script:FirebirdSessao) { $script:FirebirdSessao.Banco } else { 'C:\data\bitbar2\data\IBMASTER5.FDB' }

    # Filtro de período: as datas são aplicadas diretamente na consulta SQL.
    $lblDataInicial = New-Object System.Windows.Forms.Label
    $lblDataInicial.Text = 'Data inicial:'
    $lblDataInicial.Location = New-Object System.Drawing.Point(22, 150)
    $lblDataInicial.Size = New-Object System.Drawing.Size(100, 22)
    $dtpDataInicial = New-Object System.Windows.Forms.DateTimePicker
    $dtpDataInicial.Location = New-Object System.Drawing.Point(130, 147)
    $dtpDataInicial.Size = New-Object System.Drawing.Size(150, 24)
    $dtpDataInicial.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
    $dtpDataInicial.Value = (Get-Date).Date

    $lblDataFinal = New-Object System.Windows.Forms.Label
    $lblDataFinal.Text = 'Data final:'
    $lblDataFinal.Location = New-Object System.Drawing.Point(300, 150)
    $lblDataFinal.Size = New-Object System.Drawing.Size(75, 22)
    $dtpDataFinal = New-Object System.Windows.Forms.DateTimePicker
    $dtpDataFinal.Location = New-Object System.Drawing.Point(380, 147)
    $dtpDataFinal.Size = New-Object System.Drawing.Size(165, 24)
    $dtpDataFinal.Format = [System.Windows.Forms.DateTimePickerFormat]::Short
    $dtpDataFinal.Value = (Get-Date).Date

    $linha = New-Object System.Windows.Forms.Label
    $linha.Text = 'Autenticação (usuário/senha)'
    $linha.Font = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $linha.Location = New-Object System.Drawing.Point(22, 200)
    $linha.Size = New-Object System.Drawing.Size(300, 22)

    $lblUsuario = New-Object System.Windows.Forms.Label
    $lblUsuario.Text = 'Usuário:'
    $lblUsuario.Location = New-Object System.Drawing.Point(22, 235)
    $lblUsuario.Size = New-Object System.Drawing.Size(100, 22)
    $txtUsuario = New-Object System.Windows.Forms.TextBox
    $txtUsuario.Location = New-Object System.Drawing.Point(130, 232)
    $txtUsuario.Size = New-Object System.Drawing.Size(270, 24)
    $txtUsuario.Text = if ($script:FirebirdSessao) { $script:FirebirdSessao.Usuario } else { 'SYSDBA' }

    $lblSenha = New-Object System.Windows.Forms.Label
    $lblSenha.Text = 'Senha:'
    $lblSenha.Location = New-Object System.Drawing.Point(22, 275)
    $lblSenha.Size = New-Object System.Drawing.Size(100, 22)
    $txtSenha = New-Object System.Windows.Forms.TextBox
    $txtSenha.Location = New-Object System.Drawing.Point(130, 272)
    $txtSenha.Size = New-Object System.Drawing.Size(270, 24)
    $txtSenha.UseSystemPasswordChar = $true
    if ($script:FirebirdSessao -and $script:FirebirdSessao.Senha) { $txtSenha.Text = $script:FirebirdSessao.Senha }

    $nota = New-Object System.Windows.Forms.Label
    $nota.Text = 'A senha fica apenas na memória enquanto o script estiver aberto; ao fechar, ela será descartada.'
    $nota.ForeColor = [System.Drawing.Color]::DimGray
    $nota.Location = New-Object System.Drawing.Point(22, 315)
    $nota.Size = New-Object System.Drawing.Size(530, 35)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = 'Conectar e consultar período'
    $ok.Location = New-Object System.Drawing.Point(280, 375)
    $ok.Size = New-Object System.Drawing.Size(170, 30)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = 'Cancelar'
    $cancel.Location = New-Object System.Drawing.Point(460, 375)
    $cancel.Size = New-Object System.Drawing.Size(85, 30)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel

    $dlg.Controls.AddRange(@($lblHost, $txtHost, $lblPorta, $txtPorta, $lblBanco, $txtBanco,
        $lblDataInicial, $dtpDataInicial, $lblDataFinal, $dtpDataFinal,
        $linha, $lblUsuario, $txtUsuario, $lblSenha, $txtSenha, $nota, $ok, $cancel))
    $dlg.AcceptButton = $ok
    $dlg.CancelButton = $cancel

    if ($dlg.ShowDialog($form) -ne [System.Windows.Forms.DialogResult]::OK) {
        $dlg.Dispose()
        return $null
    }

    if ($dtpDataInicial.Value.Date -gt $dtpDataFinal.Value.Date) {
        [System.Windows.Forms.MessageBox]::Show('A data inicial não pode ser posterior à data final.', 'Período inválido', 'OK', 'Warning') | Out-Null
        $dlg.Dispose()
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($txtHost.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Informe o servidor ou IP do Firebird.', 'Servidor obrigatório', 'OK', 'Warning') | Out-Null
        $dlg.Dispose()
        return $null
    }
    if ([string]::IsNullOrWhiteSpace($txtBanco.Text)) {
        [System.Windows.Forms.MessageBox]::Show('Informe o caminho/nome do banco de dados no servidor.', 'Banco obrigatório', 'OK', 'Warning') | Out-Null
        $dlg.Dispose()
        return $null
    }

    $resultado = @{
        Servidor = $txtHost.Text.Trim()
        Porta = $txtPorta.Text.Trim()
        Banco = $txtBanco.Text.Trim()
        Usuario = $txtUsuario.Text.Trim()
        Senha = $txtSenha.Text
        DataInicial = $dtpDataInicial.Value.Date
        DataFinal = $dtpDataFinal.Value.Date
    }
    # Guarda os dados de conexão apenas em memória para permitir novas consultas
    # com outras datas sem redigitar a senha. As datas são atualizadas a cada diálogo.
    $script:FirebirdSessao = @{
        Servidor = $resultado.Servidor
        Porta = $resultado.Porta
        Banco = $resultado.Banco
        Usuario = $resultado.Usuario
        Senha = $resultado.Senha
    }
    $dlg.Dispose()
    return $resultado
}

function Consultar-LogFirebird {
    param(
        [hashtable]$Conexao,
        [System.Windows.Forms.Label]$ProgressoLabel = $null
    )

    if ($ProgressoLabel) {
        $ProgressoLabel.Text = "Preparando consulta e validando os dados..."
        $ProgressoLabel.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    }

    # Usa o utilitário oficial isql.exe da instalação do Firebird, sem driver .NET.
    $candidatos = @(
        'C:\Program Files\Firebird\Firebird_5_0\isql.exe',
        'C:\Program Files (x86)\Firebird\Firebird_5_0\isql.exe',
        (Join-Path $env:ProgramFiles 'Firebird\Firebird_5_0\isql.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Firebird\Firebird_5_0\isql.exe')
    ) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique

    $isql = $candidatos | Select-Object -First 1
    if (-not $isql) {
        throw "Não encontrei isql.exe. Verifique a instalação do Firebird e informe o caminho completo do executável."
    }
    if ([string]::IsNullOrWhiteSpace($Conexao.Senha)) {
        throw "Informe a senha do usuário Firebird."
    }

    # Campos são convertidos para uma linha delimitada por TAB. Tabs/quebras de linha
    # nos valores são substituídos para evitar corromper a leitura do resultado.
    $sql = @"
SET BAIL ON;
SET HEADING OFF;
SET LIST OFF;
SET COUNT OFF;
SET WIDTH LINHA 32767;
SELECT
  REPLACE(REPLACE(REPLACE(COALESCE(CAST(ARQUIVO AS VARCHAR(500)), ''), ASCII_CHAR(9), ' '), ASCII_CHAR(10), ' '), ASCII_CHAR(13), ' ') || ASCII_CHAR(9) ||
  COALESCE(CAST(DATA AS VARCHAR(30)), '') || ASCII_CHAR(9) ||
  REPLACE(REPLACE(REPLACE(COALESCE(CAST(USUARIO AS VARCHAR(255)), ''), ASCII_CHAR(9), ' '), ASCII_CHAR(10), ' '), ASCII_CHAR(13), ' ') || ASCII_CHAR(9) ||
  REPLACE(REPLACE(REPLACE(COALESCE(CAST(TIPO AS VARCHAR(255)), ''), ASCII_CHAR(9), ' '), ASCII_CHAR(10), ' '), ASCII_CHAR(13), ' ') || ASCII_CHAR(9) ||
  REPLACE(REPLACE(REPLACE(COALESCE(CAST(COMPUTADOR AS VARCHAR(255)), ''), ASCII_CHAR(9), ' '), ASCII_CHAR(10), ' '), ASCII_CHAR(13), ' ') || ASCII_CHAR(9) ||
  REPLACE(REPLACE(REPLACE(COALESCE(CAST(MODIFICADOS AS VARCHAR(2000)), ''), ASCII_CHAR(9), ' '), ASCII_CHAR(10), ' '), ASCII_CHAR(13), ' ') || ASCII_CHAR(9) ||
  REPLACE(REPLACE(REPLACE(COALESCE(CAST(CODIGO AS VARCHAR(255)), ''), ASCII_CHAR(9), ' '), ASCII_CHAR(10), ' '), ASCII_CHAR(13), ' ') || ASCII_CHAR(9) ||
  REPLACE(REPLACE(REPLACE(COALESCE(CAST(HISTORICO AS VARCHAR(12000)), ''), ASCII_CHAR(9), ' '), ASCII_CHAR(10), ' '), ASCII_CHAR(13), ' ') AS LINHA
FROM LOG
-- Intervalo semiaberto: inclui a data inicial e todo o dia final, inclusive horários.
WHERE DATA >= TIMESTAMP '$($Conexao.DataInicial.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)) 00:00:00' AND DATA < TIMESTAMP '$($Conexao.DataFinal.AddDays(1).ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)) 00:00:00'
ORDER BY DATA;
QUIT;
"@

    # O arquivo temporário contém a instrução CONNECT, portanto é removido em finally.
    $tempSql = Join-Path ([System.IO.Path]::GetTempPath()) ("MonitorFB_{0}.sql" -f [guid]::NewGuid().ToString('N'))
    $tempOut = Join-Path ([System.IO.Path]::GetTempPath()) ("MonitorFB_{0}.out" -f [guid]::NewGuid().ToString('N'))
    $tempErr = Join-Path ([System.IO.Path]::GetTempPath()) ("MonitorFB_{0}.err" -f [guid]::NewGuid().ToString('N'))
    $diagLog = Join-Path ([Environment]::GetFolderPath('Desktop')) 'MonitorFirebird_Diagnostico.txt'
    $registros = New-Object System.Collections.ArrayList
    try {
        $fbHost = $Conexao.Servidor.Trim()
        $porta = [int]$Conexao.Porta
        if ($porta -lt 1 -or $porta -gt 65535) { throw 'A porta informada não é válida.' }
        $banco = $Conexao.Banco.Trim()
        if ([string]::IsNullOrWhiteSpace($fbHost)) {
            throw 'Informe o servidor ou IP do Firebird. A consulta não será executada sem servidor.'
        }
        if ([string]::IsNullOrWhiteSpace($banco)) {
            throw 'Informe o caminho/nome do banco de dados no servidor. A consulta não será executada sem o banco.'
        }
        if ([string]::IsNullOrWhiteSpace($Conexao.Usuario)) {
            throw 'Informe o usuário do Firebird.'
        }
        # Escapa aspas simples na string CONNECT do isql.
        $bancoSql = $banco.Replace("'", "''")
        $usuarioSql = $Conexao.Usuario.Trim().Replace("'", "''")
        $senhaSql = $Conexao.Senha.Replace("'", "''")
        $connect = "CONNECT '$fbHost/$porta`:$bancoSql' USER '$usuarioSql' PASSWORD '$senhaSql';"
        # A senha fica somente no arquivo temporário, que é apagado após a execução.
        [System.IO.File]::WriteAllText($tempSql, $connect + "`r`n" + $sql, [System.Text.Encoding]::ASCII)
        $connectSeguro = $connect -replace "PASSWORD '[^']*'", "PASSWORD '***'"
        [System.IO.File]::WriteAllText($diagLog, "Início: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')`r`nServidor: $fbHost`r`nPorta: $porta`r`nBanco: $banco`r`nPeríodo recebido: $($Conexao.DataInicial.ToString('yyyy-MM-dd')) até $($Conexao.DataFinal.ToString('yyyy-MM-dd'))`r`nExecutável: $isql`r`nSQL enviado:`r`n$connectSeguro`r`n$sql`r`n", [System.Text.Encoding]::UTF8)

        if ($ProgressoLabel) {
            $ProgressoLabel.Text = "Conectando ao Firebird e iniciando o SQL..."
            $ProgressoLabel.Refresh()
            [System.Windows.Forms.Application]::DoEvents()
        }

        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $isql
        $psi.Arguments = '-q -i "' + $tempSql + '"'
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $proc = New-Object System.Diagnostics.Process
        $proc.StartInfo = $psi
        [void]$proc.Start()
        # IMPORTANTE: drenar stdout/stderr de forma assíncrona desde o início.
        # Se esperarmos o processo terminar antes de ler os pipes, uma consulta
        # com muitos registros pode preencher o buffer e bloquear o isql.exe.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        # Mantém a interface responsiva durante a consulta e aplica timeout.
        # O timeout evita deixar a aplicação presa indefinidamente se o servidor
        # ou a consulta não responderem.
        $limiteEspera = [DateTime]::UtcNow.AddMinutes(3)
        $proximaAtualizacao = [DateTime]::UtcNow.AddSeconds(2)
        while (-not $proc.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($ProgressoLabel -and [DateTime]::UtcNow -ge $proximaAtualizacao) {
                $ProgressoLabel.Text = "O Firebird ainda está executando a consulta..."
                $ProgressoLabel.Refresh()
                $proximaAtualizacao = [DateTime]::UtcNow.AddSeconds(2)
            }
            if ([DateTime]::UtcNow -ge $limiteEspera) {
                try { $proc.Kill() } catch {}
                throw 'A consulta ao Firebird excedeu 3 minutos e foi interrompida. Tente um período menor ou confira a conexão e o índice da coluna DATA.'
            }
            Start-Sleep -Milliseconds 100
        }
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        [System.IO.File]::WriteAllText($tempOut, $stdout, [System.Text.Encoding]::UTF8)
        [System.IO.File]::WriteAllText($tempErr, $stderr, [System.Text.Encoding]::UTF8)
        Add-Content -LiteralPath $diagLog -Encoding UTF8 -Value "ExitCode: $($proc.ExitCode)`r`nTamanho stdout: $($stdout.Length)`r`nTamanho stderr: $($stderr.Length)`r`n--- STDERR ---`r`n$stderr`r`n--- STDOUT (primeiros 12000 caracteres) ---`r`n$($stdout.Substring(0, [Math]::Min(12000, $stdout.Length)))`r`n--- Fim da resposta ---"

        if ($ProgressoLabel) {
            $ProgressoLabel.Text = "SQL finalizado. Interpretando a resposta recebida..."
            $ProgressoLabel.Refresh()
            [System.Windows.Forms.Application]::DoEvents()
        }

        if ($proc.ExitCode -ne 0 -or $stdout -match '(?im)^\s*(Statement failed|ERROR|Use CONNECT|Invalid password|Connection rejected)') {
            $detalhe = (($stderr + "`r`n" + $stdout) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 8) -join "`r`n"
            if (-not $detalhe) { $detalhe = "isql.exe terminou com código $($proc.ExitCode)." }
            throw "Falha na consulta pelo isql.exe:`r`n$detalhe"
        }

        foreach ($linha in ($stdout -split "`r?`n")) {
            $linha = $linha.Trim()
            if (-not $linha -or $linha -match '^(SQL>|Database:|Use CONNECT|Statement failed|Records affected|\(.*record.*\))') { continue }
            $partes = $linha -split "`t", 8
            if ($partes.Count -ne 8) { continue }
            $arquivo, $dataRaw, $usuario, $tipo, $computador, $modificados, $codigo, $historico = $partes
            $dataHora = $null
            $dataTexto = ''
            $horaTexto = '00:00:00'
            if ($dataRaw) {
                $parsed = [datetime]::MinValue
                $formatos = @('yyyy-MM-dd HH:mm:ss.fff','yyyy-MM-dd HH:mm:ss','yyyy-MM-dd','MM/dd/yyyy HH:mm:ss','MM/dd/yyyy')
                if ([datetime]::TryParse($dataRaw, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$parsed)) {
                    $dataHora = $parsed
                    $dataTexto = $parsed.ToString('dd/MM/yyyy')
                    $horaTexto = $parsed.ToString('HH:mm:ss')
                } else {
                    $dataTexto = $dataRaw
                }
            }
            $descricao = ((@($historico, $modificados, $codigo, $arquivo) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' | ')
            [void]$registros.Add([PSCustomObject]@{
                Secao = 'Banco de dados'; Data = $dataTexto; Hora = $horaTexto
                DataHora = if ($dataHora) { $dataHora.ToString('dd/MM/yyyy HH:mm:ss') } else { $dataTexto }
                Usuario = $usuario; Computador = $computador; Tipo = $tipo; MesaComanda = ''
                Descricao = $descricao; DescricaoRaw = $descricao; Payload = $null
                Arquivo = $arquivo; Modificados = $modificados; Codigo = $codigo; Historico = $historico
            })
        }
        Add-Content -LiteralPath $diagLog -Encoding UTF8 -Value "Linhas brutas: $((@($stdout -split "`r?`n")).Count)`r`nRegistros interpretados: $($registros.Count)`r`nFim: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        if ($ProgressoLabel) {
            $ProgressoLabel.Text = "Leitura finalizada: $($registros.Count) registro(s) interpretado(s)."
            $ProgressoLabel.Refresh()
            [System.Windows.Forms.Application]::DoEvents()
        }
        return $registros.ToArray()
    } finally {
        foreach ($f in @($tempSql, $tempOut, $tempErr)) {
            if ($f -and (Test-Path $f)) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
        }
        if ($proc) { $proc.Dispose() }
    }
}

$btnConectarFirebird.Add_Click({
    $dadosConexao = Mostrar-DialogoFirebird
    if ($null -eq $dadosConexao) { return }
    if ([string]::IsNullOrWhiteSpace($dadosConexao.Servidor)) {
        [System.Windows.Forms.MessageBox]::Show("Informe o servidor ou IP do Firebird. A consulta não será executada sem servidor.", "Dados incompletos", "OK", "Warning") | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($dadosConexao.Banco)) {
        [System.Windows.Forms.MessageBox]::Show("Informe o caminho/nome do banco de dados no servidor. A consulta não será executada sem esse caminho.", "Dados incompletos", "OK", "Warning") | Out-Null
        return
    }
    if ([string]::IsNullOrWhiteSpace($dadosConexao.Usuario)) {
        [System.Windows.Forms.MessageBox]::Show("Informe o usuário do Firebird.", "Dados incompletos", "OK", "Warning") | Out-Null
        return
    }

    # Janela de progresso modal, com barra indeterminada enquanto o SQL é executado.
    $progresso = New-Object System.Windows.Forms.Form
    $progresso.Text = "Consultando Firebird"
    $progresso.Size = New-Object System.Drawing.Size(460, 145)
    $progresso.StartPosition = "CenterParent"
    $progresso.FormBorderStyle = "FixedDialog"
    $progresso.ControlBox = $false
    $progresso.ShowInTaskbar = $false
    $lblProgresso = New-Object System.Windows.Forms.Label
    $lblProgresso.Text = "Conectando ao servidor e consultando o período selecionado..."
    $lblProgresso.Location = New-Object System.Drawing.Point(18, 15)
    $lblProgresso.Size = New-Object System.Drawing.Size(400, 35)
    $barraProgresso = New-Object System.Windows.Forms.ProgressBar
    $barraProgresso.Location = New-Object System.Drawing.Point(18, 48)
    $barraProgresso.Size = New-Object System.Drawing.Size(390, 22)
    $barraProgresso.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $barraProgresso.MarqueeAnimationSpeed = 30
    $progresso.Controls.Add($lblProgresso)
    $progresso.Controls.Add($barraProgresso)
    $progresso.Show($form)
    $progresso.Refresh()
    [System.Windows.Forms.Application]::DoEvents()
    $statusLabel.Text = "Executando consulta SQL no servidor Firebird..."
    $form.Refresh()
    try {
        $registrosBanco = @(Consultar-LogFirebird -Conexao $dadosConexao -ProgressoLabel $lblProgresso)
        $script:LogRegistros = @($registrosBanco)
        $script:SecaoSelecionada = "(todas)"
        $lblArquivo.Text = "Firebird: $($dadosConexao.Servidor) — $($dadosConexao.DataInicial.ToString('dd/MM/yyyy')) a $($dadosConexao.DataFinal.ToString('dd/MM/yyyy'))"
        Atualizar-GridSecoes
        Atualizar-GridRegistros -Secao "(todas)"
        $statusLabel.Text = "Consulta Firebird concluída: $($script:LogRegistros.Count) registros no período selecionado."
        if ($script:LogRegistros.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("A consulta terminou, mas nenhum registro foi interpretado.`r`nPeríodo: $($dadosConexao.DataInicial.ToString('dd/MM/yyyy')) a $($dadosConexao.DataFinal.ToString('dd/MM/yyyy')).`r`n`r`nObserve a última etapa mostrada na janela de progresso. Isso ajuda a identificar se a resposta veio vazia ou se as linhas não foram reconhecidas.", "Firebird - nenhum registro", "OK", "Warning") | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show("Consulta concluída. Registros encontrados no período: $($script:LogRegistros.Count).", "Firebird", "OK", "Information") | Out-Null
        }
    } catch {
        try { Add-Content -LiteralPath (Join-Path ([Environment]::GetFolderPath('Desktop')) 'MonitorFirebird_Diagnostico.txt') -Encoding UTF8 -Value "ERRO: $($_.Exception.Message)`r`nLinha: $($_.InvocationInfo.ScriptLineNumber)`r`n$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" } catch {}
        $detalheErro = $_.Exception.Message
        if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
            $detalheErro += "`r`n`r`nLinha: $($_.InvocationInfo.ScriptLineNumber)"
        }
        # Mostra a causa no rodapé também, para facilitar o diagnóstico sem depender
        # apenas da janela de erro. A consulta e o intervalo selecionado ficam explícitos.
        $dataIniDiag = if ($dadosConexao -and $dadosConexao.DataInicial) { $dadosConexao.DataInicial.ToString('dd/MM/yyyy') } else { '?' }
        $dataFimDiag = if ($dadosConexao -and $dadosConexao.DataFinal) { $dadosConexao.DataFinal.ToString('dd/MM/yyyy') } else { '?' }
        $statusLabel.Text = "Falha Firebird ($dataIniDiag a $dataFimDiag): $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Não foi possível consultar o Firebird.`r`nPeríodo: $dataIniDiag a $dataFimDiag`r`n`r`n$detalheErro", "Erro Firebird", "OK", "Error") | Out-Null
    } finally {
        if ($progresso) {
            $progresso.Close()
            $progresso.Dispose()
        }
        # A senha permanece apenas na memória da sessão para permitir outra consulta.
        # Ela é descartada no fechamento do formulário principal.
        $dadosConexao = $null
    }
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

    # >>> Limpeza dos rodapes/cabecalhos do PDF <<<
    $texto = Limpar-TextoPdf -Texto $texto

    $script:TextoBrutoPdf = $texto
    $linhasBrutas = ($texto -split "`r?`n") | Where-Object { $_.Trim() -ne "" }
    $totalLinhas = @($linhasBrutas).Count

    $preview = ($linhasBrutas | Select-Object -First 40) -join "`r`n"
    $msgDiag = @"
Texto extraido: $($texto.Length) caracteres
Linhas nao vazias: $totalLinhas

============================================================
PREVIEW DAS PRIMEIRAS 40 LINHAS NAO VAZIAS:
============================================================

$preview
"@

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
        [System.Windows.Forms.MessageBox]::Show("Texto completo copiado para a area de transferencia.`r`n`r`n","Copiado") | Out-Null
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
    $btnFecharDiag.Text = "Visualizar"
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

    $statusLabel.Text = "Parseando registros..."
    $form.Refresh()

    $script:LogRegistros = Parse-LogBitBar -TextoCompleto $texto
    $script:SecaoSelecionada = "(todas)"
    Atualizar-GridSecoes
    Atualizar-GridRegistros -Secao "(todas)"

    if ($script:LogRegistros.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show(
            "Texto foi extraido ($($texto.Length) caracteres), mas nenhum registro foi reconhecido.`r`n`r`nUse o botao 'Copiar Texto Completo' no diagnostico.",
            "Parser nao reconheceu","OK","Warning") | Out-Null
    }

    $statusLabel.Text = "Log carregado: $($script:LogRegistros.Count) registros em $(@($script:LogSecoes).Count) sessoes."
})

$txtFiltroLog.Add_TextChanged({ Atualizar-GridSecoes })
$txtBuscaLivre.Add_TextChanged({ Atualizar-GridRegistros -Secao $script:SecaoSelecionada })

$gridSecoes.Add_CellDoubleClick({
    if ($gridSecoes.SelectedRows.Count -eq 0) { return }
    $row = $gridSecoes.SelectedRows[0]
    $secao = "$($row.Cells['Secao'].Value)"
    if ($secao) {
        $script:SecaoSelecionada = $secao
        Atualizar-GridRegistros -Secao $secao
    }
})

$gridRegistros.Add_CellDoubleClick({
    if ($gridRegistros.SelectedRows.Count -eq 0) { return }
    $row = $gridRegistros.SelectedRows[0]

    $secao      = "$($row.Cells['Secao'].Value)"
    $dataHora   = "$($row.Cells['DataHora'].Value)"
    $usuario    = "$($row.Cells['Usuario'].Value)"
    $computador = "$($row.Cells['Computador'].Value)"
    $tipo       = "$($row.Cells['Tipo'].Value)"
    $mesa       = if ($gridRegistros.Columns.Contains("MesaComanda")) { "$($row.Cells['MesaComanda'].Value)" } else { "" }
    $descricao  = "$($row.Cells['Descricao'].Value)"
    $raw        = if ($gridRegistros.Columns.Contains("DescricaoRaw")) { "$($row.Cells['DescricaoRaw'].Value)" } else { $descricao }

    $cabecalho = @"
============================================================
 REGISTRO
============================================================
 Secao      : $secao
 Data/Hora  : $dataHora
 Usuario    : $usuario
 Computador : $computador
 Tipo       : $tipo
 Mesa/Com.  : $mesa

------------------------------------------------------------
 DESCRICAO
------------------------------------------------------------
$descricao

"@

    $jsonFormatado = ""
    $jsonMatch = [regex]::Match($raw, '\{.*\}')
    if ($jsonMatch.Success) {
        try {
            $obj = $jsonMatch.Value | ConvertFrom-Json
            $jsonFormatado = $obj | ConvertTo-Json -Depth 20
        } catch {
            $jsonFormatado = $jsonMatch.Value
        }
    }

    if ($jsonFormatado -ne '') {
        $conteudo = $cabecalho + @"
------------------------------------------------------------
 PAYLOAD (JSON formatado)
------------------------------------------------------------
$jsonFormatado
"@
    } else {
        $conteudo = $cabecalho
    }

    Show-DetalhesJson -Titulo "Detalhes - $secao ($tipo)" -JsonText $conteudo
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
    # Duplo clique em uma impressora abre a pagina web, usando a mesma logica do botao.
    if ($cmbModoImp.SelectedIndex -eq 1 -and $gridImp.CurrentRow) {
        $btnAbrirWebImp.PerformClick()
    }
})

# ============================================================
#  EVENTOS DOS FILTROS AVANCADOS DO LOG
# ============================================================
$txtHoraDe.Add_TextChanged({ Atualizar-GridRegistros -Secao $script:SecaoSelecionada })
$txtHoraAte.Add_TextChanged({ Atualizar-GridRegistros -Secao $script:SecaoSelecionada })
$txtMesa.Add_TextChanged({ Atualizar-GridRegistros -Secao $script:SecaoSelecionada })
$txtUsuarioLog.Add_TextChanged({ Atualizar-GridRegistros -Secao $script:SecaoSelecionada })
$cmbTipoLog.Add_SelectedIndexChanged({ Atualizar-GridRegistros -Secao $script:SecaoSelecionada })

$chkSomenteErros.Add_CheckedChanged({
    if ($chkSomenteErros.Checked) { $chkSomenteSucesso.Checked = $false }
    Atualizar-GridRegistros -Secao $script:SecaoSelecionada
})
$chkSomenteSucesso.Add_CheckedChanged({
    if ($chkSomenteSucesso.Checked) { $chkSomenteErros.Checked = $false }
    Atualizar-GridRegistros -Secao $script:SecaoSelecionada
})

$btnLimparFiltrosLog.Add_Click({
    $txtHoraDe.Text = "00:00"
    $txtHoraAte.Text = "23:59"
    $txtMesa.Text = ""
    $txtUsuarioLog.Text = ""
    $txtBuscaLivre.Text = ""
    $cmbTipoLog.SelectedIndex = 0
    $chkSomenteErros.Checked = $false
    $chkSomenteSucesso.Checked = $false
    $txtFiltroLog.Text = ""
    $script:SecaoSelecionada = "(todas)"
    Atualizar-GridRegistros -Secao "(todas)"
})


# ============================================================
#  MONITOR DE REDE - ping continuo usando recursos do Windows
#  Observacao: mede conectividade/latencia ate o IP escolhido.
#  Nao mede diretamente sinal Wi-Fi nem trafego individual por aparelho.
# ============================================================
$script:RedeHistorico = New-Object System.Collections.ArrayList
$script:RedeSucessos = 0
$script:RedeFalhas = 0
$script:RedeTimer = New-Object System.Windows.Forms.Timer
$script:RedeTimer.Interval = 2000

function Obter-InfoRedeLocal {
    # Lista os IPv4 das interfaces fisicas ativas (Ethernet e Wi-Fi), sem depender
    # exclusivamente da interface cabeada. Usa comandos nativos do Windows.
    $opcoes = @()
    try {
        $configs = @(Get-NetIPConfiguration -ErrorAction Stop | Where-Object { $_.NetAdapter.Status -eq 'Up' })
        foreach ($cfg in $configs) {
            $alias = [string]$cfg.InterfaceAlias
            # Evita adaptadores virtuais/VPN quando houver interfaces fisicas disponiveis.
            $ips = @($cfg.IPv4Address | ForEach-Object { [string]$_.IPAddress } | Where-Object {
                $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notmatch '^(127|169\.254)\.' -and
                $_ -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)'
            })
            if (-not $ips.Count) { continue }
            $gw = [string](@($cfg.IPv4DefaultGateway | ForEach-Object { $_.NextHop } | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1))
            $tipo = if ($alias -match 'Wi-?Fi|Wireless|WLAN') { 'Wi-Fi' } elseif ($alias -match 'Ethernet|Rede') { 'Ethernet' } else { $alias }
            $prioridade = 0
            if ($gw) { $prioridade += 4 }
            if ($tipo -eq 'Ethernet') { $prioridade += 1 }
            $opcoes += [PSCustomObject]@{ IP = $ips[0]; Gateway = $gw; Interface = $tipo; Prioridade = $prioridade }
        }
    } catch { }

    # Fallback para Windows onde Get-NetIPConfiguration nao estiver disponivel.
    if (-not $opcoes.Count) {
        try {
            $adaptadores = @(Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True" -ErrorAction Stop)
            foreach ($cfg in $adaptadores) {
                $ips = @($cfg.IPAddress | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' -and $_ -notmatch '^(127|169\.254)\.' -and $_ -match '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.)' })
                if (-not $ips.Count) { continue }
                $gw = [string](@($cfg.DefaultIPGateway | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' } | Select-Object -First 1))
                $tipo = if ($cfg.Description -match 'Wi-?Fi|Wireless|WLAN') { 'Wi-Fi' } elseif ($cfg.Description -match 'Ethernet') { 'Ethernet' } else { [string]$cfg.Description }
                $prioridade = [int](($gw -ne '') * 4 + ($tipo -eq 'Ethernet'))
                $opcoes += [PSCustomObject]@{ IP = $ips[0]; Gateway = $gw; Interface = $tipo; Prioridade = $prioridade }
            }
        } catch { }
    }

    if ($opcoes.Count) {
        $melhor = $opcoes | Sort-Object Prioridade -Descending | Select-Object -First 1
        $resumoIPs = (($opcoes | Sort-Object Interface -Unique | ForEach-Object { "$($_.Interface): $($_.IP)" }) -join '  |  ')
        return [PSCustomObject]@{ IP = $melhor.IP; Gateway = $melhor.Gateway; Nome = $env:COMPUTERNAME; ListaIPs = $resumoIPs }
    }
    return [PSCustomObject]@{ IP = 'Indisponivel'; Gateway = ''; Nome = $env:COMPUTERNAME; ListaIPs = 'Nenhuma interface LAN ativa identificada' }
}

$script:RedeLocal = Obter-InfoRedeLocal
$lblRedeServidor.Text = "Computador: $($script:RedeLocal.Nome)  |  $($script:RedeLocal.ListaIPs)"
$lblRedeServidor.Size = New-Object System.Drawing.Size(900, 22)
if ([string]::IsNullOrWhiteSpace($txtRedeDestino.Text) -and $script:RedeLocal.Gateway) {
    $txtRedeDestino.Text = $script:RedeLocal.Gateway
}

function Adicionar-ResultadoRede {
    param(
        [string]$Destino,
        [string]$IP,
        [string]$Latencia,
        [string]$Resultado,
        [string]$Perda
    )
    $agora = Get-Date
    $linha = [PSCustomObject]@{
        DataHora = $agora.ToString("yyyy-MM-dd HH:mm:ss")
        Destino = $Destino
        IP = $IP
        LatenciaMs = $Latencia
        Resultado = $Resultado
        PerdaAcumulada = $Perda
    }
    [void]$script:RedeHistorico.Add($linha)
    $idx = $gridRede.Rows.Add($agora.ToString("HH:mm:ss"), $Destino, $IP, $Latencia, $Resultado, $Perda)
    $row = $gridRede.Rows[$idx]
    if ($Resultado -eq "Sem resposta / timeout") {
        $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(127, 29, 29)
        $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    } elseif ($Latencia -match '^\d+$' -and [int]$Latencia -ge 100) {
        $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(120, 53, 15)
        $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    } else {
        $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(20, 30, 49)
        $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(226, 232, 240)
    }
    if ($gridRede.Rows.Count -gt 500) { $gridRede.Rows.RemoveAt(0) }
    if ($gridRede.Rows.Count -gt 0) {
        $gridRede.FirstDisplayedScrollingRowIndex = $gridRede.Rows.Count - 1
    }
}

$script:RedeTimer.Add_Tick({
    $destino = $txtRedeDestino.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($destino)) {
        $lblRedeEstado.Text = "Informe um IP valido para monitorar."
        return
    }
    try {
        $ipObj = $null
        if (-not [System.Net.IPAddress]::TryParse($destino, [ref]$ipObj)) {
            $lblRedeEstado.Text = "Informe um endereco IPv4 valido."
            return
        }
        $ping = New-Object System.Net.NetworkInformation.Ping
        try {
            $reply = $ping.Send($ipObj, 900)
        } finally {
            $ping.Dispose()
        }
        if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
            $script:RedeSucessos++
            $lat = [int]$reply.RoundtripTime
            $total = $script:RedeSucessos + $script:RedeFalhas
            $perda = [math]::Round(($script:RedeFalhas / [double]$total) * 100, 1)
            $lblRedeEstado.Text = "Respondendo | Latencia: $lat ms"
            $lblRedeEstado.ForeColor = if ($lat -ge 100) { [System.Drawing.Color]::FromArgb(251, 191, 36) } else { [System.Drawing.Color]::FromArgb(74, 222, 128) }
            Adicionar-ResultadoRede -Destino $destino -IP $reply.Address.ToString() -Latencia "$lat" -Resultado "OK" -Perda "$perda%"
        } else {
            $script:RedeFalhas++
            $total = $script:RedeSucessos + $script:RedeFalhas
            $perda = [math]::Round(($script:RedeFalhas / [double]$total) * 100, 1)
            $lblRedeEstado.Text = "Sem resposta: $($reply.Status)"
            $lblRedeEstado.ForeColor = [System.Drawing.Color]::FromArgb(248, 113, 113)
            Adicionar-ResultadoRede -Destino $destino -IP $destino -Latencia "-" -Resultado "Sem resposta / timeout" -Perda "$perda%"
        }
        $total = $script:RedeSucessos + $script:RedeFalhas
        $perdaTotal = if ($total -gt 0) { [math]::Round(($script:RedeFalhas / [double]$total) * 100, 1) } else { 0 }
        $media = if ($script:RedeSucessos -gt 0) {
            $vals = @($script:RedeHistorico | Where-Object { $_.Resultado -eq "OK" -and $_.LatenciaMs -match '^\d+$' } | Select-Object -Last 50 | ForEach-Object { [double]$_.LatenciaMs })
            if ($vals.Count -gt 0) { [math]::Round(($vals | Measure-Object -Average).Average, 1) } else { 0 }
        } else { 0 }
        $lblRedeResumo.Text = "Amostras: $total  |  Sucessos: $script:RedeSucessos  |  Falhas: $script:RedeFalhas  |  Perda acumulada: $perdaTotal%  |  Media recente: $media ms"
    } catch {
        $lblRedeEstado.Text = "Erro no teste: $($_.Exception.Message)"
        $lblRedeEstado.ForeColor = [System.Drawing.Color]::FromArgb(248, 113, 113)
    }
})

$btnRedeIniciar.Add_Click({
    $destino = $txtRedeDestino.Text.Trim()
    $ipTeste = $null
    if (-not [System.Net.IPAddress]::TryParse($destino, [ref]$ipTeste)) {
        [System.Windows.Forms.MessageBox]::Show("Informe um IPv4 valido, por exemplo 192.168.1.1.", "Diagnostico de Rede", "OK", "Warning") | Out-Null
        return
    }
    # Cada monitoramento começa uma sessão limpa, sem misturar resultados de outro IP.
    $script:RedeTimer.Stop()
    $script:RedeSucessos = 0
    $script:RedeFalhas = 0
    $script:RedeHistorico.Clear()
    $gridRede.Rows.Clear()
    $lblRedeResumo.Text = "Aguardando primeiras amostras. Intervalo: 2 segundos."
    $lblRedeEstado.Text = "Monitoramento ativo: $destino"
    $lblRedeEstado.ForeColor = [System.Drawing.Color]::FromArgb(74, 222, 128)
    $btnRedeIniciar.Enabled = $false
    $btnRedeParar.Enabled = $true
    $txtRedeDestino.Enabled = $false
    $script:RedeTimer.Start()
})

$btnRedeParar.Add_Click({
    $script:RedeTimer.Stop()
    $btnRedeIniciar.Enabled = $true
    $btnRedeParar.Enabled = $false
    $txtRedeDestino.Enabled = $true
    $lblRedeEstado.Text = "Monitoramento parado"
    $lblRedeEstado.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
})

$btnRedeExportar.Add_Click({
    if ($script:RedeHistorico.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Ainda nao existem amostras para exportar.", "Diagnostico de Rede", "OK", "Information") | Out-Null
        return
    }
    $dlgCsv = New-Object System.Windows.Forms.SaveFileDialog
    $dlgCsv.Filter = "CSV (*.csv)|*.csv"
    $dlgCsv.FileName = "DiagnosticoRede_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"
    if ($dlgCsv.ShowDialog($form) -eq [System.Windows.Forms.DialogResult]::OK) {
        try {
            $script:RedeHistorico | Export-Csv -Path $dlgCsv.FileName -NoTypeInformation -Encoding UTF8 -Delimiter ';'
            [System.Windows.Forms.MessageBox]::Show("Historico exportado com sucesso.", "Diagnostico de Rede", "OK", "Information") | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show("Falha ao exportar: $($_.Exception.Message)", "Diagnostico de Rede", "OK", "Error") | Out-Null
        }
    }
    $dlgCsv.Dispose()
})

# ============================================================
#  EVENTOS - REPARADOR DE CAMINHO / POWERSHELL REMOTING
# ============================================================
$script:AdminRedeConfigPath = Join-Path $script:BaseDir "AdminRedeConfig.json"
try {
    if (Test-Path $script:AdminRedeConfigPath) {
        $cfgAdminRede = Get-Content -LiteralPath $script:AdminRedeConfigPath -Raw | ConvertFrom-Json
        if ($cfgAdminRede.Servidor) { $txtSrvDestino.Text = [string]$cfgAdminRede.Servidor }
        if ($cfgAdminRede.Compartilhamento) { $txtCompartilhamento.Text = [string]$cfgAdminRede.Compartilhamento }
    }
} catch { }

function Escrever-LogAdminRede {
    param([string]$Mensagem)
    $linha = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $Mensagem
    if ($txtAdminLog.IsHandleCreated) {
        $txtAdminLog.AppendText($linha + [Environment]::NewLine)
    } else {
        $txtAdminLog.Text += $linha + [Environment]::NewLine
    }
}

function Obter-CaminhoCompartilhamento {
    $servidor = $txtSrvDestino.Text.Trim()
    $share = $txtCompartilhamento.Text.Trim().Trim([char[]]@([char]92, [char]47))
    if ([string]::IsNullOrWhiteSpace($servidor)) { throw "Informe o hostname ou IP do servidor." }
    if ([string]::IsNullOrWhiteSpace($share) -or $share -match '[\\/:*?"<>|]') { throw "Nome de compartilhamento invalido." }
    if ($servidor -match '[\\/:*?"<>| ]') { throw "Informe apenas hostname ou IP, sem barras ou caminho UNC." }
    return "\\$servidor\$share"
}

function Salvar-ConfigAdminRede {
    try {
        [pscustomobject]@{
            Servidor = $txtSrvDestino.Text.Trim()
            Compartilhamento = $txtCompartilhamento.Text.Trim()
        } | ConvertTo-Json | Set-Content -LiteralPath $script:AdminRedeConfigPath -Encoding UTF8
    } catch { Escrever-LogAdminRede "Aviso: nao foi possivel salvar a configuracao: $($_.Exception.Message)" }
}

$txtSrvDestino.Add_TextChanged({
    try { $lblCaminhoUNC.Text = "Caminho UNC: " + (Obter-CaminhoCompartilhamento) }
    catch { $lblCaminhoUNC.Text = "Caminho UNC: informe hostname/IP e compartilhamento." }
})
$txtCompartilhamento.Add_TextChanged({
    try { $lblCaminhoUNC.Text = "Caminho UNC: " + (Obter-CaminhoCompartilhamento) }
    catch { $lblCaminhoUNC.Text = "Caminho UNC: informe hostname/IP e compartilhamento." }
})

$btnResolverServidor.Add_Click({
    $alvo = $txtSrvDestino.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($alvo)) { [System.Windows.Forms.MessageBox]::Show("Informe o hostname ou IP do servidor.", "Resolver servidor", "OK", "Warning") | Out-Null; return }
    try {
        $ips = @([System.Net.Dns]::GetHostAddresses($alvo) | Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork } | ForEach-Object { $_.IPAddressToString } | Select-Object -Unique)
        if ($ips.Count -eq 0) { throw "Nenhum endereco IPv4 foi retornado para $alvo." }
        Escrever-LogAdminRede "Resolucao de $alvo -> $($ips -join ', ')"
        [System.Windows.Forms.MessageBox]::Show("Destino: $alvo`r`nIPv4 resolvidos: $($ips -join ', ')`r`n`r`nO hostname pode continuar sendo usado no caminho UNC, desde que a resolucao funcione nos PDVs.", "Resolver servidor", "OK", "Information") | Out-Null
    } catch {
        Escrever-LogAdminRede "Falha ao resolver ${alvo}: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel resolver o destino.`r`n$($_.Exception.Message)", "Resolver servidor", "OK", "Warning") | Out-Null
    }
})

$btnTestarPasta.Add_Click({
    try {
        $unc = Obter-CaminhoCompartilhamento
        Escrever-LogAdminRede "Testando compartilhamento $unc"
        $hostAlvo = $txtSrvDestino.Text.Trim()
        $tcpOk = $false
        try { $tcpOk = (Test-NetConnection -ComputerName $hostAlvo -Port 445 -WarningAction SilentlyContinue -InformationLevel Quiet -ErrorAction Stop) } catch { $tcpOk = $false }
        if ($tcpOk) { Escrever-LogAdminRede "Porta SMB 445 acessivel em $hostAlvo." }
        else { Escrever-LogAdminRede "Porta SMB 445 nao respondeu. Verifique rede/firewall/servidor." }
        if (Test-Path -LiteralPath $unc -ErrorAction SilentlyContinue) {
            Escrever-LogAdminRede "SUCESSO: compartilhamento acessivel com a sessao atual: $unc"
            [System.Windows.Forms.MessageBox]::Show("O compartilhamento esta acessivel:`r`n$unc", "Reparador de caminho", "OK", "Information") | Out-Null
        } else {
            Escrever-LogAdminRede "O caminho nao esta acessivel com as credenciais atuais: $unc"
            [System.Windows.Forms.MessageBox]::Show("Nao foi possivel acessar $unc com a sessao atual.`r`nSe for necessario, use 'Conectar com credenciais'.", "Reparador de caminho", "OK", "Warning") | Out-Null
        }
        Salvar-ConfigAdminRede
    } catch {
        Escrever-LogAdminRede "ERRO ao testar compartilhamento: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Reparador de caminho", "OK", "Warning") | Out-Null
    }
})

$btnAbrirPasta.Add_Click({
    try {
        $unc = Obter-CaminhoCompartilhamento
        if (-not (Test-Path -LiteralPath $unc -ErrorAction SilentlyContinue)) {
            [System.Windows.Forms.MessageBox]::Show("O caminho nao respondeu com as credenciais atuais. Tente conectar com credenciais primeiro.", "Reparador de caminho", "OK", "Warning") | Out-Null
            return
        }
        Start-Process -FilePath "explorer.exe" -ArgumentList $unc
        Escrever-LogAdminRede "Pasta aberta: $unc"
    } catch { Escrever-LogAdminRede "ERRO ao abrir pasta: $($_.Exception.Message)" }
})

$btnCopiarUNC.Add_Click({
    try {
        $unc = Obter-CaminhoCompartilhamento
        [System.Windows.Forms.Clipboard]::SetText($unc)
        Escrever-LogAdminRede "Caminho copiado: $unc"
    } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Reparador de caminho", "OK", "Warning") | Out-Null }
})

$btnConectarPasta.Add_Click({
    try {
        $unc = Obter-CaminhoCompartilhamento
        $letra = $txtUnidade.Text.Trim().TrimEnd(':').ToUpper()
        if ($letra -notmatch '^[A-Z]$') { throw "Informe uma letra de unidade valida, por exemplo Z:." }
        $drive = "${letra}:"
        if (Get-PSDrive -Name $letra -ErrorAction SilentlyContinue) {
            [System.Windows.Forms.MessageBox]::Show("A unidade $drive ja existe nesta sessao. Escolha outra letra ou verifique o mapeamento atual.", "Reparador de caminho", "OK", "Warning") | Out-Null
            return
        }
        $cred = Get-Credential -Message "Informe uma conta autorizada a acessar $unc (ex.: NOMEPC\bituser ou NOMEPC\bitbar)."
        if ($null -eq $cred) { Escrever-LogAdminRede "Conexao cancelada pelo usuario."; return }
        New-PSDrive -Name $letra -PSProvider FileSystem -Root $unc -Credential $cred -Persist -Scope Global -ErrorAction Stop | Out-Null
        Escrever-LogAdminRede "Unidade $drive conectada a $unc. Credenciais mantidas apenas pela sessao do Windows."
        Salvar-ConfigAdminRede
        Start-Process -FilePath "explorer.exe" -ArgumentList "$drive\"
        [System.Windows.Forms.MessageBox]::Show("Conexao criada: $drive -> $unc", "Reparador de caminho", "OK", "Information") | Out-Null
    } catch {
        Escrever-LogAdminRede "ERRO ao conectar compartilhamento: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel criar a conexao.`r`n$($_.Exception.Message)`r`n`r`nSe houver uma conexao SMB existente para o mesmo servidor com outro usuario, o Windows pode bloquear credenciais diferentes.", "Reparador de caminho", "OK", "Error") | Out-Null
    }
})

$btnTestarWinRM.Add_Click({
    $alvo = $txtSrvDestino.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($alvo)) { [System.Windows.Forms.MessageBox]::Show("Informe o hostname/IP do computador remoto.", "PowerShell Remoting", "OK", "Warning") | Out-Null; return }
    try {
        Test-WSMan -ComputerName $alvo -ErrorAction Stop | Out-Null
        Escrever-LogAdminRede "WinRM respondeu em $alvo."
        [System.Windows.Forms.MessageBox]::Show("WinRM esta respondendo em $alvo. Ja e possivel tentar uma sessao autenticada.", "PowerShell Remoting", "OK", "Information") | Out-Null
    } catch {
        Escrever-LogAdminRede "WinRM nao esta disponivel em ${alvo}: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("WinRM nao respondeu em $alvo.`r`nSe estiver desabilitado, e necessario preparar o destino por um canal administrativo ja disponivel ou executar o comando nele localmente.", "PowerShell Remoting", "OK", "Warning") | Out-Null
    }
})

$btnPrepararRemoto.Add_Click({
    $alvo = $txtSrvDestino.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($alvo)) { [System.Windows.Forms.MessageBox]::Show("Informe o hostname/IP do computador remoto.", "PowerShell Remoting", "OK", "Warning") | Out-Null; return }
    $confirm = [System.Windows.Forms.MessageBox]::Show("Isto tentara executar Enable-PSRemoting no computador $alvo usando credenciais administrativas. O WinRM precisa estar acessivel antes desta etapa. Continuar?", "Confirmar preparacao remota", "YesNo", "Warning")
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $cred = Get-Credential -Message "Credenciais administrativas para $alvo"
        if ($null -eq $cred) { return }
        Invoke-Command -ComputerName $alvo -Credential $cred -ScriptBlock {
            Enable-PSRemoting -Force -ErrorAction Stop
            [pscustomobject]@{ Computador = $env:COMPUTERNAME; WinRM = (Get-Service WinRM).Status.ToString(); Resultado = 'Enable-PSRemoting executado' }
        } -ErrorAction Stop | ForEach-Object { Escrever-LogAdminRede "Destino $($_.Computador): $($_.Resultado); WinRM=$($_.WinRM)" }
        [System.Windows.Forms.MessageBox]::Show("Comando executado no destino. Consulte o log para o resultado.", "PowerShell Remoting", "OK", "Information") | Out-Null
    } catch {
        Escrever-LogAdminRede "ERRO ao preparar $alvo remotamente: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel executar a preparacao remota.`r`n$($_.Exception.Message)`r`n`r`nSe o WinRM ainda estiver desabilitado, este comando nao consegue inicializar o primeiro acesso sozinho.", "PowerShell Remoting", "OK", "Error") | Out-Null
    }
})

$btnDesligarRemoto.Add_Click({
    $alvo = $txtSrvDestino.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($alvo)) {
        [System.Windows.Forms.MessageBox]::Show("Informe o hostname ou IP do computador que deseja desligar.", "Desligar computador", "OK", "Warning") | Out-Null
        return
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show("Tem certeza que deseja DESLIGAR o computador $alvo? Salve qualquer trabalho aberto antes de continuar.", "Confirmar desligamento remoto", "YesNo", "Warning")
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $cred = Get-Credential -Message "Informe uma conta administrativa autorizada para $alvo"
        if ($null -eq $cred) { Escrever-LogAdminRede "Desligamento cancelado: credenciais nao informadas."; return }
        Escrever-LogAdminRede "Enviando comando de desligamento para $alvo..."
        Invoke-Command -ComputerName $alvo -Credential $cred -ScriptBlock {
            & "$env:WINDIR\System32\shutdown.exe" /s /t 10 /c "Desligamento remoto solicitado pelo suporte"
            if ($LASTEXITCODE -ne 0) { throw "shutdown.exe retornou codigo $LASTEXITCODE" }
            "Desligamento agendado para daqui a 10 segundos."
        } -ErrorAction Stop | ForEach-Object { Escrever-LogAdminRede ([string]$_) }
        Escrever-LogAdminRede "Comando de desligamento enviado para ${alvo}; desligamento agendado para 10 segundos."
        [System.Windows.Forms.MessageBox]::Show("Desligamento agendado para $alvo em 10 segundos.", "Desligamento remoto", "OK", "Information") | Out-Null
    } catch {
        Escrever-LogAdminRede "ERRO ao desligar ${alvo}: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel concluir o desligamento remoto.`r`n$($_.Exception.Message)", "Desligamento remoto", "OK", "Error") | Out-Null
    }
})

$btnReiniciarRemoto.Add_Click({
    $alvo = $txtSrvDestino.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($alvo)) {
        [System.Windows.Forms.MessageBox]::Show("Informe o hostname ou IP do computador que deseja reiniciar.", "Reiniciar computador", "OK", "Warning") | Out-Null
        return
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show("Tem certeza que deseja REINICIAR o computador $alvo? O sistema e as sessoes abertas serao interrompidos.", "Confirmar reinicializacao remota", "YesNo", "Warning")
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $cred = Get-Credential -Message "Informe uma conta administrativa autorizada para $alvo"
        if ($null -eq $cred) { Escrever-LogAdminRede "Reinicializacao cancelada: credenciais nao informadas."; return }
        Escrever-LogAdminRede "Enviando comando de reinicializacao para $alvo..."
        Invoke-Command -ComputerName $alvo -Credential $cred -ScriptBlock {
            & "$env:WINDIR\System32\shutdown.exe" /r /t 10 /c "Reinicializacao remota solicitada pelo suporte"
            if ($LASTEXITCODE -ne 0) { throw "shutdown.exe retornou codigo $LASTEXITCODE" }
            "Reinicializacao agendada para daqui a 10 segundos."
        } -ErrorAction Stop | ForEach-Object { Escrever-LogAdminRede ([string]$_) }
        Escrever-LogAdminRede "Comando de reinicializacao enviado para ${alvo}; reinicializacao agendada para 10 segundos."
        [System.Windows.Forms.MessageBox]::Show("Reinicializacao agendada para $alvo em 10 segundos.", "Reinicializacao remota", "OK", "Information") | Out-Null
    } catch {
        Escrever-LogAdminRede "AVISO ao reiniciar ${alvo}: a sessao pode ter sido encerrada pelo proprio reinicio. Detalhe: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("A conexao pode cair quando o computador inicia o reinicio. Verifique se $alvo esta reiniciando antes de tentar novamente.`r`n`r`nDetalhe: $($_.Exception.Message)", "Reinicializacao remota", "OK", "Warning") | Out-Null
    }
})

$btnRenovarIPRemoto.Add_Click({
    $alvo = $txtSrvDestino.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($alvo)) {
        [System.Windows.Forms.MessageBox]::Show("Informe o hostname ou IP do computador que deseja renovar o IP.", "Renovar IP remoto", "OK", "Warning") | Out-Null
        return
    }
    $confirm = [System.Windows.Forms.MessageBox]::Show("O comando ipconfig /release pode interromper a conexao com $alvo e a sessao WinRM pode cair antes da renovacao terminar.`r`n`r`nDeseja continuar?", "Confirmar renovacao de IP", "YesNo", "Warning")
    if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $cred = Get-Credential -Message "Informe uma conta administrativa autorizada para $alvo"
        if ($null -eq $cred) { Escrever-LogAdminRede "Renovacao de IP cancelada: credenciais nao informadas."; return }
        Escrever-LogAdminRede "Solicitando ipconfig /release e /renew em $alvo..."
        $resultado = Invoke-Command -ComputerName $alvo -Credential $cred -ScriptBlock {
            $ipconfig = Join-Path $env:WINDIR 'System32\ipconfig.exe'
            $saidaRelease = & $ipconfig /release 2>&1 | Out-String
            Start-Sleep -Seconds 2
            $saidaRenew = & $ipconfig /renew 2>&1 | Out-String
            [pscustomobject]@{
                Computador = $env:COMPUTERNAME
                Release = $saidaRelease.Trim()
                Renew = $saidaRenew.Trim()
            }
        } -ErrorAction Stop
        foreach ($item in $resultado) {
            Escrever-LogAdminRede "Renovacao executada em $($item.Computador)."
            if ($item.Release) { Escrever-LogAdminRede ("Release: " + (($item.Release -replace '[\r\n]+',' | ').Trim())) }
            if ($item.Renew) { Escrever-LogAdminRede ("Renew: " + (($item.Renew -replace '[\r\n]+',' | ').Trim())) }
        }
        [System.Windows.Forms.MessageBox]::Show("Os comandos de liberacao e renovacao foram executados em $alvo. Confira o log; a renovacao pode levar alguns segundos para restabelecer a rede.", "Renovar IP remoto", "OK", "Information") | Out-Null
    } catch {
        Escrever-LogAdminRede "ERRO/CONEXAO INTERROMPIDA durante renovacao de IP em ${alvo}: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("A sessao remota foi interrompida ou a operacao falhou.`r`nComo o IP foi liberado, aguarde alguns segundos e tente localizar o computador pelo novo IP/hostname antes de repetir.`r`n`r`nDetalhe: $($_.Exception.Message)", "Renovar IP remoto", "OK", "Warning") | Out-Null
    }
})

$btnTrustedHost.Add_Click({
    $alvo = $txtSrvDestino.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($alvo)) { [System.Windows.Forms.MessageBox]::Show("Informe hostname ou IP do destino.", "TrustedHosts", "OK", "Warning") | Out-Null; return }
    try {
        $path = 'WSMan:\localhost\Client\TrustedHosts'
        $atual = (Get-Item -Path $path -ErrorAction Stop).Value
        $lista = @($atual -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($lista -notcontains $alvo) { $lista += $alvo }
        Set-Item -Path $path -Value ($lista -join ',') -Force -ErrorAction Stop
        Escrever-LogAdminRede "TrustedHosts local atualizado para incluir somente o destino especifico: $alvo"
        [System.Windows.Forms.MessageBox]::Show("Destino adicionado ao TrustedHosts deste computador:`r`n$alvo`r`n`r`nEsta alteracao e local e pode exigir executar o script como administrador.", "TrustedHosts", "OK", "Information") | Out-Null
    } catch {
        Escrever-LogAdminRede "ERRO ao atualizar TrustedHosts: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel atualizar TrustedHosts. Execute como administrador.`r`n$($_.Exception.Message)", "TrustedHosts", "OK", "Error") | Out-Null
    }
})

$btnPrepararLocal.Add_Click({
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        [System.Windows.Forms.MessageBox]::Show("Execute o MonitorDesligamentos como administrador para habilitar o WinRM neste computador.", "PowerShell Remoting", "OK", "Warning") | Out-Null
        return
    }
    try {
        Enable-PSRemoting -Force -ErrorAction Stop | Out-Null
        Escrever-LogAdminRede "Enable-PSRemoting executado neste computador ($env:COMPUTERNAME)."
        [System.Windows.Forms.MessageBox]::Show("PowerShell Remoting habilitado neste computador.", "PowerShell Remoting", "OK", "Information") | Out-Null
    } catch {
        Escrever-LogAdminRede "ERRO ao habilitar WinRM local: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "PowerShell Remoting", "OK", "Error") | Out-Null
    }
})

$btnCopiarPreparacao.Add_Click({
    $comando = "Enable-PSRemoting -Force"
    try {
        [System.Windows.Forms.Clipboard]::SetText($comando)
        Escrever-LogAdminRede "Comando copiado. Execute-o em PowerShell elevado no computador que deve receber conexoes remotas: $comando"
        [System.Windows.Forms.MessageBox]::Show("Comando copiado para a area de transferencia:`r`n`r`n$comando`r`n`r`nExecute no computador de destino em um PowerShell aberto como administrador.", "Preparar destino", "OK", "Information") | Out-Null
    } catch { Escrever-LogAdminRede "ERRO ao copiar comando: $($_.Exception.Message)" }
})

# ============================================================
#  INICIALIZACAO
# ============================================================
if ($chkAuto.Checked) { $timer.Start() }

$form.Add_FormClosing({
    $timer.Stop()
    if ($script:RedeTimer) { $script:RedeTimer.Stop(); $script:RedeTimer.Dispose() }
    if ($script:FirebirdSessao) {
        $script:FirebirdSessao.Senha = $null
        $script:FirebirdSessao = $null
    }
})

if ($sidebar.Controls.Count -gt 3) {
    foreach ($control in $sidebar.Controls) {
        if ($control -is [System.Windows.Forms.Button] -and [int]$control.Tag -eq 0) {
            $control.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
            $control.ForeColor = [System.Drawing.Color]::White
        }
    }
}

$form.Add_Shown({
    Carregar-Desligamentos
})

[void]$form.ShowDialog()
$form.Dispose()
