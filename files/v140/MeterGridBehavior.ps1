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
