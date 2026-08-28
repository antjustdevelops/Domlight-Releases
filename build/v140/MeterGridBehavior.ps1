$ErrorActionPreference = 'Stop'

function Enable-MeterGridImmediateCommit {
    param(
        [Parameter(Mandatory=$true)]
        [System.Windows.Forms.DataGridView]$Grid
    )

    $Grid.Add_CurrentCellDirtyStateChanged({
        if (-not $Grid.IsCurrentCellDirty) { return }
        $cell = $Grid.CurrentCell
        if ($null -eq $cell) { return }
        $column = $cell.OwningColumn
        if ($null -eq $column) { return }
        if ([string]$column.Name -ne 'Selected') { return }
        [void]$Grid.CommitEdit([System.Windows.Forms.DataGridViewDataErrorContexts]::Commit)
    })
}

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
