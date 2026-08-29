$ErrorActionPreference = 'Stop'

function Complete-MeterGridEdit {
    param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Forms.DataGridView]$Grid
    )

    if ($Grid.IsCurrentCellDirty) {
        [void]$Grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    }
    [void]$Grid.EndEdit()
}

function Save-MeterDraftsFromGrid {
    param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Forms.DataGridView]$Grid,
        [Parameter(Mandatory=$true)]
        [string]$Account,
        [Parameter(Mandatory=$true)]
        [hashtable]$Drafts,
        [Parameter(Mandatory=$true)]
        [string]$Path
    )

    Complete-MeterGridEdit -Grid $Grid

    foreach ($row in $Grid.Rows) {
        $meterId = [string]$row.Tag
        if ([string]::IsNullOrWhiteSpace($meterId)) { continue }

        $selected = $false
        if ($null -ne $row.Cells['Selected'].Value) {
            $selected = [bool]$row.Cells['Selected'].Value
        }
        $value = [string]$row.Cells['NewValue'].Value
        $key = $Account + '|' + $meterId
        $Drafts[$key] = [pscustomobject]@{
            Selected = $selected
            Value = $value
        }
    }

    Export-MeterDraftStore -Drafts $Drafts -Path $Path
}

function Test-MeterNewValue {
    param([object]$Value)
    $text=([string]$Value).Trim()
    if([string]::IsNullOrWhiteSpace($text)){ return $false }
    return ($text -match '^\d+(?:[\.,]\d+)?$')
}

function Set-MeterRowSelectionAvailability {
    param([System.Windows.Forms.DataGridViewRow]$Row)
    if($null -eq $Row){ return }
    $selectedCell=$Row.Cells['Selected']
    $valueCell=$Row.Cells['NewValue']
    if($null -eq $selectedCell -or $null -eq $valueCell){ return }
    if($selectedCell.Style.BackColor -eq [System.Drawing.Color]::Gainsboro){ return }
    $valid=Test-MeterNewValue $valueCell.Value
    if(-not $valid){
        $selectedCell.Value=$false
        $selectedCell.ReadOnly=$true
    } else {
        $selectedCell.ReadOnly=$false
    }
}

function Enable-MeterGridSelectionRules {
    param([Parameter(Mandatory=$true)][System.Windows.Forms.DataGridView]$Grid)
    foreach($row in $Grid.Rows){ Set-MeterRowSelectionAvailability -Row $row }
    $Grid.Add_CellEndEdit({
        param($sender,$e)
        if($e.RowIndex -ge 0 -and $sender.Columns[$e.ColumnIndex].Name -eq 'NewValue'){
            Set-MeterRowSelectionAvailability -Row $sender.Rows[$e.RowIndex]
        }
    })
    $Grid.Add_CellValueChanged({
        param($sender,$e)
        if($e.RowIndex -ge 0 -and $e.ColumnIndex -ge 0 -and $sender.Columns[$e.ColumnIndex].Name -eq 'NewValue'){
            Set-MeterRowSelectionAvailability -Row $sender.Rows[$e.RowIndex]
        }
    })
}
