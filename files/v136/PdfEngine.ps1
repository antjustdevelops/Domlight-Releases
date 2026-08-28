$ErrorActionPreference='Stop'

function Get-PdfTextDirect {
    param([Parameter(Mandatory=$true)][string]$Path)
    if(-not(Test-Path -LiteralPath $Path)){throw "PDF not found: $Path"}

    # Preferred path: Poppler pdftotext if installed or shipped next to Domlight.
    $root=Split-Path -Parent $MyInvocation.MyCommand.Path
    $candidates=@(
        (Join-Path $root 'pdftotext.exe'),
        (Join-Path $root 'tools\pdftotext.exe'),
        'pdftotext.exe'
    )
    foreach($exe in $candidates){
        try{
            $resolved=$null
            if([IO.Path]::IsPathRooted($exe)){
                if(Test-Path -LiteralPath $exe){$resolved=$exe}
            }else{
                $cmd=Get-Command $exe -ErrorAction SilentlyContinue
                if($cmd){$resolved=$cmd.Source}
            }
            if($resolved){
                $tmp=[IO.Path]::GetTempFileName()
                try{
                    & $resolved -layout -enc UTF-8 -- $Path $tmp 2>$null
                    if($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $tmp)){
                        $text=Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
                        if(-not[string]::IsNullOrWhiteSpace($text)){return $text}
                    }
                }finally{Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue}
            }
        }catch{}
    }

    # Windows fallback: Microsoft Word can open text-based PDFs and expose their text.
    $word=$null;$doc=$null
    try{
        $word=New-Object -ComObject Word.Application
        $word.Visible=$false
        $word.DisplayAlerts=0
        $doc=$word.Documents.Open($Path,$false,$true)
        $text=[string]$doc.Content.Text
        if(-not[string]::IsNullOrWhiteSpace($text)){return $text}
    }catch{}
    finally{
        if($doc){try{$doc.Close([ref]0)}catch{}}
        if($word){try{$word.Quit()}catch{}}
        if($doc){try{[Runtime.InteropServices.Marshal]::ReleaseComObject($doc)|Out-Null}catch{}}
        if($word){try{[Runtime.InteropServices.Marshal]::ReleaseComObject($word)|Out-Null}catch{}}
    }

    throw 'Не удалось извлечь текст из PDF. Установите pdftotext (Poppler) или Microsoft Word.'
}
