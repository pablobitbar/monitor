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
    @{ Text = "  Log do Sistema / PDF"; Index = 3 }
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
foreach ($page in @($tabDesligamentos, $tabCredenciais, $tabImpressoras, $tabLogSistema)) {
    $page.BackColor = $darkBack
    $page.ForeColor = $textColor
}
foreach ($grid in @($gridDesl, $gridCred, $gridImp, $gridSecoes, $gridRegistros)) {
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
foreach ($page in @($tabDesligamentos, $tabCredenciais, $tabImpressoras, $tabLogSistema)) {
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
            ($_.DescricaoRaw -like "*$termo*")
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
    if ($desc) {
        $descStr = "$desc"
        if (Test-ErroLog $descStr) {
            $e.CellStyle.BackColor = [System.Drawing.Color]::FromArgb(127, 29, 29)
            $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(254, 202, 202)
        }
        elseif (Test-SucessoLog $descStr) {
            $e.CellStyle.BackColor = [System.Drawing.Color]::FromArgb(20, 83, 45)
            $e.CellStyle.ForeColor = [System.Drawing.Color]::FromArgb(187, 247, 208)
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
#  INICIALIZACAO
# ============================================================
if ($chkAuto.Checked) { $timer.Start() }

$form.Add_FormClosing({
    $timer.Stop()
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
