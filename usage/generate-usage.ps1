$results = @()
$sessionData = @()
$chatNames = @{}
$projectNames = @{}

$paths = @(
    "$env:USERPROFILE\.claude\projects",
    "$env:APPDATA\Agents Dev",
    "$env:APPDATA\21st-desktop"
)

# Read chat names from agents.db using Python
$dbPath = "$env:APPDATA\21st-desktop\data\agents.db"
if (Test-Path $dbPath) {
    $pythonScript = @"
import sqlite3, json
conn = sqlite3.connect(r'$dbPath')
cursor = conn.cursor()
cursor.execute('''
    SELECT sc.id, sc.name, c.name as chat_name, p.name as project_name, p.path as project_path
    FROM sub_chats sc
    LEFT JOIN chats c ON sc.chat_id = c.id
    LEFT JOIN projects p ON c.project_id = p.id
''')
data = {}
for row in cursor.fetchall():
    data[row[0]] = {
        'subChatName': row[1] or '',
        'chatName': row[2] or '',
        'projectName': row[3] or '',
        'projectPath': row[4] or ''
    }
print(json.dumps(data))
"@
    
    try {
        $chatDataJson = $pythonScript | python 2>$null
        if ($chatDataJson) {
            $chatData = $chatDataJson | ConvertFrom-Json
            $chatData.PSObject.Properties | ForEach-Object {
                $chatNames[$_.Name] = $_.Value.subChatName
                $projectNames[$_.Name] = $_.Value.projectName
            }
        }
    } catch {
        Write-Host "Warning: Could not read chat names from database: $_"
    }
}

foreach ($basePath in $paths) {
    if (Test-Path $basePath) {
        Get-ChildItem $basePath -Recurse -Filter "*.jsonl" -ErrorAction SilentlyContinue | ForEach-Object {
            $file = $_
            $filePath = $file.FullName
            $isSubagent = $filePath -match 'subagents'
            
            # Get session folder name (this matches sub_chats.id)
            $sessionFolder = ""
            if ($filePath -match 'claude-sessions[\\\/]([^\\\/]+)') {
                $sessionFolder = $matches[1]
            }
            
            # Get session ID from filename or parent folder
            if ($isSubagent) {
                $parentPath = Split-Path (Split-Path $file.DirectoryName -Parent) -Leaf
                $mainSessionId = $parentPath
            } else {
                $mainSessionId = $file.BaseName
            }
            
            # Extract project name from path (fallback)
            $projectFallback = ""
            if ($filePath -match 'projects[\\\/]([^\\\/]+)') {
                $projectFallback = $matches[1] -replace '^[A-Z]--','' -replace '--',' - ' -replace '-',' '
            }
            
            # Get chat name from database
            $chatName = ""
            $projectName = ""
            
            if ($chatNames.ContainsKey($sessionFolder)) {
                $chatName = $chatNames[$sessionFolder]
                $projectName = $projectNames[$sessionFolder]
            }
            
            if (-not $chatName) {
                # Fallback: read first user message
                $firstLines = Get-Content $file.FullName -TotalCount 20 -ErrorAction SilentlyContinue
                foreach ($line in $firstLines) {
                    if ($line -match '"type"\s*:\s*"user"' -and $line -match '"text"\s*:\s*"([^"]{1,60})') {
                        $chatName = $matches[1] -replace '\\n.*','' -replace '[\r\n]','' -replace '"',''
                        break
                    }
                }
            }
            
            if (-not $chatName) { $chatName = $mainSessionId.Substring(0, [Math]::Min(8, $mainSessionId.Length)) + "..." }
            if (-not $projectName) { $projectName = $projectFallback }
            if (-not $projectName) { $projectName = "Unknown Project" }
            
            # Clean names for JSON safety
            $chatName = $chatName -replace '[\\"]', ''
            $projectName = $projectName -replace '[\\"]', ''
            
            $sessionKey = "$sessionFolder|$mainSessionId"
            
            $content = Get-Content $file.FullName -ErrorAction SilentlyContinue
            foreach ($line in $content) {
                $date = $null
                if ($line -match '"timestamp"\s*:\s*"(\d{4}-\d{2}-\d{2})') {
                    $date = $matches[1]
                }
                if (-not $date) { continue }
                
                $input = 0; $output = 0; $cacheCreate = 0; $cacheRead = 0
                if ($line -match '"input_tokens"\s*:\s*(\d+)') { $input = [int]$matches[1] }
                if ($line -match '"output_tokens"\s*:\s*(\d+)') { $output = [int]$matches[1] }
                if ($line -match '"cache_creation_input_tokens"\s*:\s*(\d+)') { $cacheCreate = [int]$matches[1] }
                if ($line -match '"cache_read_input_tokens"\s*:\s*(\d+)') { $cacheRead = [int]$matches[1] }
                
                if ($input -gt 0 -or $output -gt 0 -or $cacheCreate -gt 0 -or $cacheRead -gt 0) {
                    $results += @{date=$date; input=$input; output=$output; cacheCreate=$cacheCreate; cacheRead=$cacheRead}
                    $sessionData += @{
                        date=$date
                        session=$sessionKey
                        sessionId=$mainSessionId
                        chatName=$chatName
                        project=$projectName
                        input=$input
                        output=$output
                        cacheCreate=$cacheCreate
                        cacheRead=$cacheRead
                    }
                }
            }
        }
    }
}

# Convert to JSON safely
if ($results.Count -eq 0) { $jsonData = "[]" }
else { $jsonData = ($results | ConvertTo-Json -Compress -Depth 5) -replace '[\r\n]','' }

if ($sessionData.Count -eq 0) { $sessionJson = "[]" }
else { $sessionJson = ($sessionData | ConvertTo-Json -Compress -Depth 5) -replace '[\r\n]','' }

$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

# Build HTML using single-quoted here-string to avoid $ interpolation
$htmlTemplate = @'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Claude Code Usage Dashboard</title>
    <style>
        *{margin:0;padding:0;box-sizing:border-box}body{font-family:'Segoe UI',sans-serif;background:linear-gradient(135deg,#1a1a2e,#16213e);min-height:100vh;padding:20px;color:#fff}.container{max-width:1200px;margin:0 auto}h1{text-align:center;margin-bottom:10px;font-size:2.5rem;background:linear-gradient(90deg,#00d4ff,#7b2cbf);-webkit-background-clip:text;-webkit-text-fill-color:transparent}.subtitle{text-align:center;color:#888;margin-bottom:10px}.refresh-time{text-align:center;color:#666;font-size:.8rem;margin-bottom:30px}.controls{display:flex;justify-content:center;gap:15px;margin-bottom:30px;flex-wrap:wrap}select{padding:10px 20px;border-radius:8px;border:1px solid #333;background:#252540;color:#fff;font-size:1rem;cursor:pointer}.stats-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:20px;margin-bottom:30px}.stat-card{background:rgba(255,255,255,.05);border-radius:16px;padding:25px;text-align:center;border:1px solid rgba(255,255,255,.1);transition:all .3s}.stat-card:hover{transform:translateY(-5px);border-color:rgba(0,212,255,.5)}.stat-card.total{background:linear-gradient(135deg,rgba(0,212,255,.2),rgba(123,44,191,.2))}.stat-icon{font-size:1.2rem;margin-bottom:10px;color:#888}.stat-label{color:#888;font-size:.9rem;margin-bottom:5px}.stat-value{font-size:1.6rem;font-weight:700}.stat-card:nth-child(1) .stat-value{color:#00d4ff}.stat-card:nth-child(2) .stat-value{color:#7b2cbf}.stat-card:nth-child(3) .stat-value{color:#f39c12}.stat-card:nth-child(4) .stat-value{color:#2ecc71}.stat-card.total .stat-value{color:#fff;font-size:2.2rem}.alert-banner{background:linear-gradient(135deg,#e74c3c,#c0392b);border-radius:12px;padding:20px;margin-bottom:30px;text-align:center;display:none;animation:pulse 2s infinite}.alert-banner.warning{background:linear-gradient(135deg,#f39c12,#e67e22)}.alert-banner.danger{background:linear-gradient(135deg,#e74c3c,#c0392b)}.alert-banner h3{margin-bottom:5px}.alert-banner p{opacity:.9}@keyframes pulse{0%,100%{opacity:1}50%{opacity:.8}}.cost-breakdown,.daily-breakdown,.session-breakdown{background:rgba(255,255,255,.05);border-radius:16px;padding:25px;margin-bottom:30px;border:1px solid rgba(255,255,255,.1)}.cost-breakdown h3{margin-bottom:20px;color:#00d4ff}.daily-breakdown h3,.session-breakdown h3{margin-bottom:20px;color:#7b2cbf}.cost-row{display:flex;justify-content:space-between;padding:10px 0;border-bottom:1px solid rgba(255,255,255,.1)}.cost-row:last-child{border-bottom:none;font-weight:700;font-size:1.2rem;color:#2ecc71}.cost-label{color:#aaa}table{width:100%;border-collapse:collapse}th,td{padding:12px;text-align:right;border-bottom:1px solid rgba(255,255,255,.1)}th{color:#888;font-weight:400}th:first-child,td:first-child{text-align:left}tr:hover{background:rgba(255,255,255,.05)}.no-data{text-align:center;color:#666;padding:40px}.session-name{max-width:350px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:.85rem}.chat-name{color:#00d4ff;font-weight:500;display:block;margin-bottom:3px}.project-name{color:#666;font-size:.75rem}.session-filters{margin-bottom:15px;display:flex;align-items:center;gap:10px;flex-wrap:wrap}.session-filters select{padding:8px 15px}.high-cost{color:#e74c3c!important;font-weight:700}.warning-cost{color:#f39c12!important}.top-session{background:rgba(231,76,60,.1)!important}.tabs{display:flex;gap:10px;margin-bottom:20px}.tab-btn{padding:10px 20px;background:rgba(255,255,255,.1);border:none;border-radius:8px;color:#fff;cursor:pointer;transition:all .3s}.tab-btn.active{background:linear-gradient(135deg,#00d4ff,#7b2cbf)}.tab-content{display:none}.tab-content.active{display:block}
    </style>
</head>
<body>
    <div class="container">
        <h1>Claude Code Usage</h1>
        <p class="subtitle">Claude CLI + 1Code Usage Tracker</p>
        <p class="refresh-time">Last updated: {{TIMESTAMP}}</p>
        
        <div class="alert-banner" id="alertBanner">
            <h3 id="alertTitle">Warning</h3>
            <p id="alertMsg">Daily spending threshold exceeded!</p>
        </div>
        
        <div class="controls">
            <label>Show: </label>
            <select id="days" onchange="filterData()">
                <option value="0">Today</option>
                <option value="7" selected>Last 7 days</option>
                <option value="14">Last 14 days</option>
                <option value="30">Last 30 days</option>
                <option value="all">All time</option>
            </select>
            <label>Alert at: </label>
            <select id="threshold" onchange="filterData()">
                <option value="10">$10/day</option>
                <option value="15" selected>$15/day</option>
                <option value="25">$25/day</option>
                <option value="50">$50/day</option>
            </select>
        </div>
        
        <div class="stats-grid">
            <div class="stat-card"><div class="stat-icon">INPUT</div><div class="stat-label">Input Tokens</div><div class="stat-value" id="inputTokens">-</div></div>
            <div class="stat-card"><div class="stat-icon">OUTPUT</div><div class="stat-label">Output Tokens</div><div class="stat-value" id="outputTokens">-</div></div>
            <div class="stat-card"><div class="stat-icon">CACHE+</div><div class="stat-label">Cache Create</div><div class="stat-value" id="cacheCreate">-</div></div>
            <div class="stat-card"><div class="stat-icon">CACHE</div><div class="stat-label">Cache Read</div><div class="stat-value" id="cacheRead">-</div></div>
            <div class="stat-card total"><div class="stat-icon">COST</div><div class="stat-label">Estimated Cost</div><div class="stat-value" id="totalCost">-</div></div>
        </div>
        
        <div class="cost-breakdown">
            <h3>Cost Breakdown (Opus 4.5)</h3>
            <div class="cost-row"><span class="cost-label">Input ($15/1M)</span><span id="inputCost">$0</span></div>
            <div class="cost-row"><span class="cost-label">Output ($75/1M)</span><span id="outputCost">$0</span></div>
            <div class="cost-row"><span class="cost-label">Cache Create ($1.875/1M)</span><span id="cacheCreateCost">$0</span></div>
            <div class="cost-row"><span class="cost-label">Cache Read ($0.1875/1M)</span><span id="cacheReadCost">$0</span></div>
            <div class="cost-row"><span class="cost-label">Total</span><span id="totalCostBreakdown">$0</span></div>
        </div>
        
        <div class="tabs">
            <button class="tab-btn active" onclick="switchTab('daily')">Daily Breakdown</button>
            <button class="tab-btn" onclick="switchTab('sessions')">Session Breakdown</button>
        </div>
        
        <div id="dailyTab" class="tab-content active">
            <div class="daily-breakdown">
                <h3>Daily Breakdown</h3>
                <table><thead><tr><th>Date</th><th>Input</th><th>Output</th><th>Cache+</th><th>Cache</th><th>Cost</th><th>Status</th></tr></thead><tbody id="dailyTable"></tbody></table>
            </div>
        </div>
        
        <div id="sessionsTab" class="tab-content">
            <div class="session-breakdown">
                <h3>Most Expensive Sessions</h3>
                <div class="session-filters">
                    <label>Filter by date: </label>
                    <select id="sessionDateFilter" onchange="filterData()"><option value="all">All dates in range</option></select>
                    <label>Filter by project: </label>
                    <select id="sessionProjectFilter" onchange="filterData()"><option value="all">All projects</option></select>
                </div>
                <table><thead><tr><th>Chat / Project</th><th>Date</th><th>Input</th><th>Output</th><th>Cache+</th><th>Cost</th></tr></thead><tbody id="sessionTable"></tbody></table>
            </div>
        </div>
    </div>
    <script>
        var allData = {{ALLDATA}};
        var sessionData = {{SESSIONDATA}};
        
        function calcCost(i,o,cc,cr){return (i/1e6)*15+(o/1e6)*75+(cc/1e6)*1.875+(cr/1e6)*0.1875;}
        
        function switchTab(t){
            document.querySelectorAll('.tab-btn').forEach(function(b){b.classList.remove('active')});
            document.querySelectorAll('.tab-content').forEach(function(c){c.classList.remove('active')});
            if(t==='daily'){
                document.querySelectorAll('.tab-btn')[0].classList.add('active');
                document.getElementById('dailyTab').classList.add('active');
            }else{
                document.querySelectorAll('.tab-btn')[1].classList.add('active');
                document.getElementById('sessionsTab').classList.add('active');
            }
        }
        
        function escapeHtml(t){return t?String(t).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;'):''}
        
        function filterData(){
            var d=document.getElementById('days').value;
            var threshold=parseFloat(document.getElementById('threshold').value);
            var f=Array.isArray(allData)?allData:(allData?[allData]:[]);
            var sf=Array.isArray(sessionData)?sessionData:(sessionData?[sessionData]:[]);
            var today=new Date();today.setHours(0,0,0,0);
            var todayStr=today.toISOString().split('T')[0];
            
            if(d==='0'){f=f.filter(function(x){return x.date===todayStr});sf=sf.filter(function(x){return x.date===todayStr});}
            else if(d!=='all'){var cut=new Date();cut.setDate(cut.getDate()-parseInt(d));var cutStr=cut.toISOString().split('T')[0];f=f.filter(function(x){return x.date>=cutStr});sf=sf.filter(function(x){return x.date>=cutStr});}
            
            var byDate={};
            f.forEach(function(x){if(!byDate[x.date])byDate[x.date]={input:0,output:0,cacheCreate:0,cacheRead:0};byDate[x.date].input+=x.input||0;byDate[x.date].output+=x.output||0;byDate[x.date].cacheCreate+=x.cacheCreate||0;byDate[x.date].cacheRead+=x.cacheRead||0;});
            
            var bySession={};
            sf.forEach(function(x){
                var key=x.session+'|'+x.date;
                if(!bySession[key])bySession[key]={session:x.session,sessionId:x.sessionId,chatName:x.chatName,project:x.project,date:x.date,input:0,output:0,cacheCreate:0,cacheRead:0};
                bySession[key].input+=x.input||0;
                bySession[key].output+=x.output||0;
                bySession[key].cacheCreate+=x.cacheCreate||0;
                bySession[key].cacheRead+=x.cacheRead||0;
            });
            
            var ti=0,to=0,tc=0,tr=0;
            Object.values(byDate).forEach(function(x){ti+=x.input;to+=x.output;tc+=x.cacheCreate;tr+=x.cacheRead;});
            var ic=(ti/1e6)*15,oc=(to/1e6)*75,cc=(tc/1e6)*1.875,rc=(tr/1e6)*0.1875,tot=ic+oc+cc+rc;
            
            document.getElementById('inputTokens').textContent=ti.toLocaleString();
            document.getElementById('outputTokens').textContent=to.toLocaleString();
            document.getElementById('cacheCreate').textContent=tc.toLocaleString();
            document.getElementById('cacheRead').textContent=tr.toLocaleString();
            document.getElementById('totalCost').textContent='$'+tot.toFixed(2);
            document.getElementById('inputCost').textContent='$'+ic.toFixed(4);
            document.getElementById('outputCost').textContent='$'+oc.toFixed(4);
            document.getElementById('cacheCreateCost').textContent='$'+cc.toFixed(4);
            document.getElementById('cacheReadCost').textContent='$'+rc.toFixed(4);
            document.getElementById('totalCostBreakdown').textContent='$'+tot.toFixed(2);
            
            var alertBanner=document.getElementById('alertBanner');
            var todayCost=byDate[todayStr]?calcCost(byDate[todayStr].input,byDate[todayStr].output,byDate[todayStr].cacheCreate,byDate[todayStr].cacheRead):0;
            var highDays=Object.entries(byDate).filter(function(e){return calcCost(e[1].input,e[1].output,e[1].cacheCreate,e[1].cacheRead)>=threshold});
            
            if(todayCost>=threshold){
                alertBanner.style.display='block';
                alertBanner.className='alert-banner danger';
                document.getElementById('alertTitle').textContent='Today Spending Alert!';
                document.getElementById('alertMsg').textContent='Today: $'+todayCost.toFixed(2)+' (threshold: $'+threshold+')';
            }else if(highDays.length>0){
                alertBanner.style.display='block';
                alertBanner.className='alert-banner warning';
                document.getElementById('alertTitle').textContent='High Usage Days Detected';
                document.getElementById('alertMsg').textContent=highDays.length+' day(s) exceeded $'+threshold+' threshold';
            }else{alertBanner.style.display='none';}
            
            var tbody=document.getElementById('dailyTable');
            var dates=Object.keys(byDate).sort().reverse();
            if(!dates.length){tbody.innerHTML='<tr><td colspan="7" class="no-data">No data</td></tr>';}
            else{
                tbody.innerHTML=dates.map(function(dt){
                    var x=byDate[dt];
                    var c=calcCost(x.input,x.output,x.cacheCreate,x.cacheRead);
                    var costClass=c>=threshold?'high-cost':c>=threshold*0.7?'warning-cost':'';
                    var status=c>=threshold?'Over':'OK';
                    return '<tr><td>'+dt+'</td><td>'+x.input.toLocaleString()+'</td><td>'+x.output.toLocaleString()+'</td><td>'+x.cacheCreate.toLocaleString()+'</td><td>'+x.cacheRead.toLocaleString()+'</td><td class="'+costClass+'">$'+c.toFixed(2)+'</td><td>'+status+'</td></tr>';
                }).join('');
            }
            
            var sessionDateFilter=document.getElementById('sessionDateFilter');
            var sessionDates=[];
            Object.values(bySession).forEach(function(s){if(sessionDates.indexOf(s.date)===-1)sessionDates.push(s.date)});
            sessionDates.sort().reverse();
            var currentDateVal=sessionDateFilter.value;
            sessionDateFilter.innerHTML='<option value="all">All dates in range</option>'+sessionDates.map(function(dt){return '<option value="'+dt+'">'+dt+'</option>'}).join('');
            if(sessionDates.indexOf(currentDateVal)!==-1||currentDateVal==='all')sessionDateFilter.value=currentDateVal;
            
            var sessionProjectFilter=document.getElementById('sessionProjectFilter');
            var projects=[];
            Object.values(bySession).forEach(function(s){if(s.project&&projects.indexOf(s.project)===-1)projects.push(s.project)});
            projects.sort();
            var currentProjVal=sessionProjectFilter.value;
            sessionProjectFilter.innerHTML='<option value="all">All projects</option>'+projects.map(function(p){return '<option value="'+escapeHtml(p)+'">'+escapeHtml(p)+'</option>'}).join('');
            if(projects.indexOf(currentProjVal)!==-1||currentProjVal==='all')sessionProjectFilter.value=currentProjVal;
            
            var stbody=document.getElementById('sessionTable');
            var sessionDateVal=sessionDateFilter.value;
            var sessionProjVal=sessionProjectFilter.value;
            var filteredSessions=Object.values(bySession);
            if(sessionDateVal!=='all')filteredSessions=filteredSessions.filter(function(s){return s.date===sessionDateVal});
            if(sessionProjVal!=='all')filteredSessions=filteredSessions.filter(function(s){return s.project===sessionProjVal});
            var sessions=filteredSessions.map(function(s){s.cost=calcCost(s.input,s.output,s.cacheCreate,s.cacheRead);return s}).sort(function(a,b){return b.cost-a.cost}).slice(0,25);
            
            if(!sessions.length){stbody.innerHTML='<tr><td colspan="6" class="no-data">No session data</td></tr>';}
            else{
                stbody.innerHTML=sessions.map(function(s,i){
                    var isTop=i===0&&s.cost>5;
                    var costClass=s.cost>=10?'high-cost':s.cost>=5?'warning-cost':'';
                    var chatDisplay=escapeHtml(s.chatName||'Unnamed chat');
                    var projectDisplay=escapeHtml(s.project||'Unknown');
                    var trophy=i===0?'[TOP] ':'';
                    return '<tr class="'+(isTop?'top-session':'')+'"><td class="session-name" title="'+escapeHtml(s.sessionId)+'"><span class="chat-name">'+trophy+chatDisplay+'</span><span class="project-name">'+projectDisplay+'</span></td><td>'+s.date+'</td><td>'+s.input.toLocaleString()+'</td><td>'+s.output.toLocaleString()+'</td><td>'+s.cacheCreate.toLocaleString()+'</td><td class="'+costClass+'">$'+s.cost.toFixed(2)+'</td></tr>';
                }).join('');
            }
        }
        filterData();
    </script>
</body>
</html>
'@

# Replace placeholders
$html = $htmlTemplate -replace '\{\{TIMESTAMP\}\}', $timestamp
$html = $html -replace '\{\{ALLDATA\}\}', $jsonData
$html = $html -replace '\{\{SESSIONDATA\}\}', $sessionJson

[System.IO.File]::WriteAllText("D:\UbuntuContainer\codebase\1code\usage\claude-usage.html", $html, [System.Text.UTF8Encoding]::new($false))
Write-Host "Dashboard generated! Results: $($results.Count) token records, $($sessionData.Count) session records"