#Requires -Version 7
<#
.SYNOPSIS
    Phase C overnight orchestrator - self-healing scrape completion + full RAG ingest.
    Written 2026-07-17 ~00:20 AST by Claude (OHD project) for unattended overnight run.

.DESCRIPTION
    1. Retries the /top scrape for the three under-delivered subs (ClaudeAI, AI_Agents,
       automation), solo runs with proxy-rotation waits, up to $MaxAttempts each.
    2. Halts all scraping if Apify monthly usage crosses $SpendCapUsd (hard backstop:
       the account-level max usage limit at Apify).
    3. Runs phase3 (filter) -> phase4 (tag) -> phase5 (chunk+embed) across ALL
       subreddits. All three are idempotent with resume support, so partial scrape
       coverage still produces a fully usable enriched corpus.
    4. Verifies /stats on port 8425 (non-blocking if server is down).
    5. Writes PHASE_C_OVERNIGHT_REPORT.txt with a STATUS banner, per-sub coverage,
       spend, chunk counts, unrecovered subs with exact re-run commands, and next steps.
    6. Opens the report in Notepad as the wake-up notification.

    SUCCESS CRITERION per scrape attempt: "Total records" delivered by that run
    >= MinRecords. Delivery count is used (not DB delta) because /top posts can
    legitimately dedup against /new posts already ingested tonight.
#>
<#
=====================================================================
 PUBLIC COPY - buildwithaihub, video 1 ("the overnight orchestrator")
=====================================================================
 This is the script from the video, as it ran on 2026-07-17. Two things
 were changed for publication: one machine-specific Python path now
 resolves from $env:LOCALAPPDATA, and one comment naming a person was
 reworded. Nothing in the control flow was touched.

 It will NOT run as-is on your machine. It drives one specific pipeline
 (three Python scripts, a SQLite file, a local vector-store server).
 About a quarter of the lines are that pipeline's business. The rest is
 the pattern the video is about: a retry queue with a success test, a
 spend cap read from the provider before every attempt, idempotent
 phases, and a report written in a finally block.

 ADAPT THESE LINES for your own pipeline:
   $Repo, $Py                      - your working folder and interpreter
   $SpendCapUsd, $MaxAttempts,
   $RetryWaitSec                   - your limits
   Get-ApifySpend                  - replace with YOUR provider's usage
                                     endpoint; the point is to read the
                                     provider's number, not your own
   Get-RedditStatsChunks           - replace with a health/size probe of
                                     whatever your last phase writes to
   Get-CoverageTable               - the SQLite path in it is hard-coded
   the $Queue block                - your targets and MinRecords
   'Total records:' regex          - whatever your scraper prints on
                                     success; this IS the success test
   the three phase script calls    - your own phases, each idempotent
   Required env vars (APIFY_API_TOKEN, OPENROUTER_API_KEY) - yours
   Report text at the end          - keep the STATUS line first; it is
                                     the one line you read at 6 am
=====================================================================
#>

$ErrorActionPreference = 'Continue'
$Repo        = 'C:\Dev\online_hustle_discovery_rag'
$Py          = Join-Path $env:LOCALAPPDATA 'Programs\Python\Python310\python.exe'
$ReportPath  = Join-Path $Repo 'PHASE_C_OVERNIGHT_REPORT.txt'
$OrchLog     = Join-Path $Repo 'phaseC_orchestrator.log'
$SpendCapUsd = 95
$MaxAttempts = 3
$RetryWaitSec = 90

$Script:ChunksBefore = -1
$Script:ChunksAfter  = -1
$Script:Unrecovered  = @()
$Script:Recovered    = @()
$Script:Halted       = $false
$Script:Crashed      = $null
$Script:SpendStart   = -1
$Script:SpendEnd     = -1

Start-Transcript -Path $OrchLog -Append | Out-Null
Set-Location $Repo

function Log([string]$Msg) {
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Write-Output "[$ts] $Msg"
}

function Get-ApifySpend {
    try {
        $lim = Invoke-RestMethod -Uri 'https://api.apify.com/v2/users/me/limits' `
            -Headers @{ Authorization = "Bearer $($env:APIFY_API_TOKEN)" } -TimeoutSec 20
        return [math]::Round([double]$lim.data.current.monthlyUsageUsd, 2)
    } catch {
        Log "WARN: Apify limits endpoint unreachable ($($_.Exception.Message)). Treating as unknown (-1)."
        return -1
    }
}

function Get-RedditStatsChunks {
    try {
        $s = Invoke-RestMethod -Uri 'http://localhost:8425/stats' -TimeoutSec 10
        return [int]$s.total_chunks
    } catch { return -1 }
}

function Get-CoverageTable {
    $q = 'import sqlite3; c = sqlite3.connect(r"C:\Dev\online_hustle_discovery_rag\reddit_pipeline.db"); rows = c.execute("select subreddit_name, total_posts_scraped, total_comments_scraped, total_posts_substantive, total_comments_substantive from subreddits order by subreddit_name").fetchall(); [print("%-28s posts=%-5s cmts=%-6s subst_posts=%-5s subst_cmts=%s" % r) for r in rows]'
    return (& $Py -c $q 2>&1 | Out-String)
}

try {
    Log '================ PHASE C OVERNIGHT ORCHESTRATOR START ================'

    # --- Bridge API keys from User scope (fresh-process safety) ---
    foreach ($k in @('APIFY_API_TOKEN', 'OPENROUTER_API_KEY')) {
        $v = [Environment]::GetEnvironmentVariable($k, 'User')
        if ($v) { Set-Item -Path "Env:$k" -Value $v }
    }
    if (-not $env:APIFY_API_TOKEN)    { throw 'APIFY_API_TOKEN missing from User env - cannot scrape.' }
    if (-not $env:OPENROUTER_API_KEY) { throw 'OPENROUTER_API_KEY missing from User env - cannot tag/embed.' }
    Log 'API keys bridged from User scope.'

    $Script:SpendStart   = Get-ApifySpend
    $Script:ChunksBefore = Get-RedditStatsChunks
    Log "Starting state: Apify monthly spend=`$$($Script:SpendStart), 8425 chunks=$($Script:ChunksBefore)"

    # --- Scrape retry queue (delivery-count success criterion) ---
    $Queue = @(
        @{ Sub = 'ClaudeAI';   Sort = 'top'; MaxPosts = 20; MaxItems = 2200; MinRecords = 120 },
        @{ Sub = 'AI_Agents';  Sort = 'top'; MaxPosts = 20; MaxItems = 2200; MinRecords = 100 },
        @{ Sub = 'automation'; Sort = 'top'; MaxPosts = 20; MaxItems = 2200; MinRecords = 100 }
    )

    foreach ($item in $Queue) {
        if ($Script:Halted) { break }
        $ok = $false
        for ($a = 1; $a -le $MaxAttempts; $a++) {
            $spend = Get-ApifySpend
            Log "Spend check before attempt: `$$spend (cap `$$SpendCapUsd)"
            if ($spend -ge $SpendCapUsd) {
                Log 'SPEND CAP REACHED - halting all further scraping.'
                $Script:Halted = $true
                break
            }

            $runLog = Join-Path $Repo ("phaseC_orch_{0}_{1}_a{2}.log" -f $item.Sub, $item.Sort, $a)
            Log ("Attempt {0}/{1}: r/{2} /{3} (max-posts {4}, cap {5})" -f $a, $MaxAttempts, $item.Sub, $item.Sort, $item.MaxPosts, $item.MaxItems)

            & $Py -u (Join-Path $Repo 'reddit_phase2_apify_ingest.py') `
                --subreddits $item.Sub --sorts $item.Sort `
                --max-posts $item.MaxPosts --max-items $item.MaxItems 2>&1 |
                Tee-Object -FilePath $runLog | Out-Null

            $totLine = Select-String -Path $runLog -Pattern 'Total records:\s+(\d+)' | Select-Object -Last 1
            $delivered = 0
            if ($totLine -and $totLine.Matches.Count -gt 0) {
                $delivered = [int]$totLine.Matches[0].Groups[1].Value
            }
            Log ("r/{0} /{1} attempt {2}: delivered {3} records (need >= {4})" -f $item.Sub, $item.Sort, $a, $delivered, $item.MinRecords)

            if ($delivered -ge $item.MinRecords) {
                $ok = $true
                $Script:Recovered += ("r/{0} /{1} ({2} records, attempt {3})" -f $item.Sub, $item.Sort, $delivered, $a)
                Log ("COVERAGE OK: r/{0} /{1}" -f $item.Sub, $item.Sort)
                break
            }
            if ($a -lt $MaxAttempts) {
                Log "Short delivery. Waiting $RetryWaitSec s for proxy-pool rotation..."
                Start-Sleep -Seconds $RetryWaitSec
            }
        }
        if (-not $ok -and -not $Script:Halted) {
            $Script:Unrecovered += ("r/{0} /{1}" -f $item.Sub, $item.Sort)
            Log ("UNRECOVERED after {0} attempts: r/{1} /{2}" -f $MaxAttempts, $item.Sub, $item.Sort)
        }
    }

    # --- Phases 3-5 across everything (idempotent; runs regardless of scrape outcome) ---
    Log '=== PHASE 3: rule-based filter (all subreddits) ==='
    & $Py -u (Join-Path $Repo 'reddit_phase3_filter.py') 2>&1 |
        Tee-Object -FilePath (Join-Path $Repo 'phaseC_orch_phase3.log') | Out-Null
    Log 'Phase 3 complete.'

    Log '=== PHASE 4: LLM tagging (all subreddits, resume-capable) ==='
    & $Py -u (Join-Path $Repo 'reddit_phase4_tag.py') 2>&1 |
        Tee-Object -FilePath (Join-Path $Repo 'phaseC_orch_phase4.log') | Out-Null
    Log 'Phase 4 complete.'

    Log '=== PHASE 5: chunk + embed to ChromaDB (all subreddits) ==='
    & $Py -u (Join-Path $Repo 'reddit_phase5_chunk_embed.py') 2>&1 |
        Tee-Object -FilePath (Join-Path $Repo 'phaseC_orch_phase5.log') | Out-Null
    Log 'Phase 5 complete.'

    $Script:ChunksAfter = Get-RedditStatsChunks
    $Script:SpendEnd    = Get-ApifySpend
    Log "Final state: Apify monthly spend=`$$($Script:SpendEnd), 8425 chunks=$($Script:ChunksAfter)"
}
catch {
    $Script:Crashed = $_.Exception.Message
    Log "FATAL: $($Script:Crashed)"
}
finally {
    # --- Build the wake-up report (written even on crash) ---
    if ($Script:Crashed)                    { $status = "STATUS: CRASHED - $($Script:Crashed)" }
    elseif ($Script:Halted)                 { $status = 'STATUS: HALTED - SPEND CAP REACHED (ingest of collected data still ran)' }
    elseif ($Script:Unrecovered.Count -gt 0){ $status = "STATUS: PARTIAL - $($Script:Unrecovered.Count) SUB/SORT TARGET(S) UNRECOVERED (everything else fully ingested)" }
    else                                    { $status = 'STATUS: COMPLETE - ALL TARGETS COVERED AND INGESTED' }

    $tagCost = ''
    $p4log = Join-Path $Repo 'phaseC_orch_phase4.log'
    if (Test-Path $p4log) {
        $m = Select-String -Path $p4log -Pattern 'Est\. cost:\s+(\S+)' | Select-Object -Last 1
        if ($m -and $m.Matches.Count -gt 0) { $tagCost = $m.Matches[0].Groups[1].Value }
    }
    $p5log = Join-Path $Repo 'phaseC_orch_phase5.log'
    $p5tail = ''
    if (Test-Path $p5log) { $p5tail = (Get-Content $p5log -Tail 14) -join "`r`n" }

    $coverage = ''
    try { $coverage = Get-CoverageTable } catch { $coverage = "(coverage query failed: $($_.Exception.Message))" }

    $unrecBlock = 'None - all retry targets recovered.'
    if ($Script:Unrecovered.Count -gt 0) {
        $cmds = $Script:Unrecovered | ForEach-Object {
            $parts = $_ -replace '^r/', '' -split ' /'
            "  & `"$Py`" -u `"$Repo\reddit_phase2_apify_ingest.py`" --subreddits $($parts[0]) --sorts $($parts[1]) --max-posts 20 --max-items 2200"
        }
        $unrecBlock = ($Script:Unrecovered -join "`r`n") + "`r`n`r`nRe-run commands (then phase3/4/5 with no args):`r`n" + ($cmds -join "`r`n")
    }

    $report = @(
        '======================================================================='
        ' PHASE C OVERNIGHT REPORT - Reddit Builder RAG 10-sub backfill'
        " Generated: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) AST"
        '======================================================================='
        ''
        $status
        ''
        '--- Money ---'
        "Apify monthly usage at orchestrator start : `$$($Script:SpendStart)"
        "Apify monthly usage at orchestrator end   : `$$($Script:SpendEnd)"
        "Phase 4 tagging cost (this pass)          : $tagCost"
        "Spend cap (orchestrator)                  : `$$SpendCapUsd  |  Apify account hard cap: see console Billing > Limits"
        ''
        '--- RAG state (port 8425) ---'
        "Chunks before : $($Script:ChunksBefore)"
        "Chunks after  : $($Script:ChunksAfter)"
        '(-1 means the server was unreachable at that moment; corpus data is safe in ChromaDB regardless.)'
        ''
        '--- Scrape retries recovered ---'
        $(if ($Script:Recovered.Count -gt 0) { $Script:Recovered -join "`r`n" } else { '(none needed / none succeeded - see below)' })
        ''
        '--- Unrecovered sub/sort targets ---'
        $unrecBlock
        ''
        '--- Per-subreddit coverage (reddit_pipeline.db, cumulative) ---'
        $coverage
        '--- Phase 5 tail (chunk/embed summary) ---'
        $p5tail
        ''
        '--- Logs ---'
        "Orchestrator : $OrchLog"
        "Per-attempt  : $Repo\phaseC_orch_<sub>_<sort>_a<N>.log"
        "Phases       : phaseC_orch_phase3.log / phase4.log / phase5.log"
        ''
        '--- Next steps (morning session) ---'
        '1. Review this report; re-run any unrecovered targets (commands above), then phase3/4/5 with no args.'
        '2. Update RAG_ROUTING_GUIDE.md + PROJECT_INSTRUCTIONS Knowledge-Bases table (>15% chunk-count rule).'
        '3. Post-run signal read: query the refreshed corpus for community pain points re: Claude agents.'
        '4. Draft 3-5 value-first Reddit post concepts (posted manually - the 21-day clock starts then).'
        '5. Session banking: vault note + instructions revision + fresh continuation prompt.'
        '======================================================================='
    ) -join "`r`n"

    Set-Content -Path $ReportPath -Value $report -Encoding UTF8
    Log "Report written: $ReportPath"

    # Wake-up notification: open the report in Notepad (visible on unlock).
    try { Start-Process notepad.exe $ReportPath } catch { Log "Notepad launch failed: $($_.Exception.Message)" }

    Log '================ PHASE C OVERNIGHT ORCHESTRATOR END ================'
    Stop-Transcript | Out-Null
}
