<#!
.SYNOPSIS
    Job Objects fail-closed para contencao de arvore de processos no runtime
    V2 (RR-P22-JOB-OBJECTS, V3.1).
.DESCRIPTION
    Lib dot-sourceable, PS 5.1 e PS7 compativel (sem ternario, sem ??, sem
    Invoke-Expression), ASCII only. Nao executa nada no dot-source alem de
    registrar o coletor C# (Add-Type, uma vez por sessao): so define funcoes.

    POR QUE (fecha o BLOCKER documentado da P22): cleanup por arvore
    (CIM / ParentProcessId) perde descendants em dois cenarios:
    (a) o filho gera um neto DEPOIS do snapshot da arvore (a coleta ja
    terminou; o neto nunca e visto); (b) o filho morre antes do snapshot e o
    neto e reparentado (o walk por ParentProcessId nao acha mais a ligacao).
    Membership de Job Object fecha os dois: a associacao e por ARVORE DE
    CRIACAO (herdada no create do processo), imune a PID-reuse e a morte do
    pai.

    Garantias implementadas (so fatos, sem claim alem do codigo):
      - New-RuntimeJobObject: CreateJobObjectW + SetInformationJobObject com
        SOMENTE JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE (0x00002000); os demais
        campos de JOBOBJECT_EXTENDED_LIMIT_INFORMATION sao zerados (nenhum
        limite de memoria/quantidade e introduzido). NAO sao setados
        JOB_OBJECT_LIMIT_BREAKAWAY_OK (0x00000800) nem
        JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK (0x00001000): sem essas flags um
        filho DENTRO do job nao consegue criar processo fora do job por
        breakaway (o create falha com acesso negado), logo a contencao nao e
        burlada por um filho que tente escapar do job.
      - Add-RuntimeJobProcess: AssignProcessToJobObject. CONTRATO PUBLICO
        (FIX1/F1): exige o System.Diagnostics.Process retido do spawn PROPRIO
        e usa o handle JA exposto pelo .NET (o objeto do kernel real, imune a
        PID-reuse). NAO existe caminho por PID: OpenProcess por PID nao carrega
        prova de ownership nem de creation-time, entao um PID reciclado faria a
        lib atribuir (e depois encerrar) um processo TERCEIRO. Handle
        indisponivel => recusa estruturada {Ok=false; Reason}. O processo
        ATUAL (o host desta lib) e SEMPRE recusado.
      - Attach-RuntimeJobVerifiedProcess (RR-P26-JOB-WIRING): mesma
        atribuicao por handle retido, porem para uma instancia JA PROVADA
        pelo chamador (o enforcement do watchdog, que fixou identidade +
        liveness na propria instancia pinada). Re-verifica barato ANTES do
        Assign: liveness (HasExited) e identidade (ticks de criacao UTC da
        MESMA instancia, com tolerancia explicita; default 0 = exata).
        NUNCA OpenProcess por PID (delega a atribuicao real ao
        Add-RuntimeJobProcess, cujo contrato fica INTACTO), recusa host-self
        e recusa identidade ausente/divergente. Falha => resultado
        estruturado {Ok=false; Reason}, o enforcement segue pelo caminho CIM
        de sempre (fail-closed, nunca fail-open).
      - New-RuntimeJobObject -NoKillOnClose: cria o job SEM
        JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, entao Close e INERTE e o unico
        ato letal passa a ser TerminateJobObject. Default (sem switch)
        inalterado: KILL_ON_JOB_CLOSE com close letal. Usado pelo
        enforcement para que um REFUSED (nada morto) nunca mate o processo
        que ele reporta como nao morto.
      - Get-RuntimeJobMemberPids: QueryInformationJobObject
        (JobObjectBasicProcessIdList) com enumeracao BOUNDED. O cap e
        PARAMETRO (default 256). Excesso do cap => lista PARCIAL dos slots
        preenchidos pelo SO com Truncated=true, NUNCA lista vazia e NUNCA
        excecao (FIX1/F5). FIX2/G1 + FIX3/H-A: no caminho de overflow os
        contadores (Assigned/listed) sao lidos INCONDICIONALMENTE do SEGUNDO
        buffer, o unico com o tamanho pedido, para que Assigned e os PIDs
        extraidos descrevam a MESMA consulta (os contadores do probe de 1 slot
        descreveriam outra). Assigned preserva o CONTADOR REAL do SO e nunca e
        rebaixado ao cap: com 3 membros e cap=1 => 1 PID + Assigned=3 +
        Truncated=true. O cap limita SO a quantidade de slots extraidos.
      - Get-RuntimeJobLimitFlags: leitura das flags por
        QueryInformationJobObject (prova de breakaway negado).
      - Stop-RuntimeJobObject: TerminateJobObject + settlement BOUNDED por
        DEADLINE ABSOLUTO (polling do member list; mesmo padrao de deadline da
        P22). FIX1/F3: cada espera e min(PollMs, restante ate o deadline) e
        PollMs tem teto => o deadline e respeitado mesmo com PollMs enorme.
        FIX1/F4: consulta de membros que falha no settlement produz Ok=false
        com Api/Reason propagados (fail-closed), preservando Terminated=true e
        sem sobrescrever Truncated. FIX2/G2: os switches internos
        -FaultInjectQueryAfterTerminate e -FaultInjectSkipTerminate existem SO
        para teste; nenhum caminho de producao os liga. FIX3/H-E: a injecao de
        falha de consulta usa um dicionario LOCAL de handle zero, sem tocar o
        job real, de modo que o handle nativo permanece integro e fechavel (o
        job real nao vaza).
      - Close-RuntimeJobObject: CloseHandle; com KILL_ON_JOB_CLOSE e o
        backstop final (fechar o handle sem Stop encerra os membros).
      - TODA falha de API vira resultado estruturado {Ok=false; Reason; Api} e
        NUNCA excecao atravessando a seam. Nada aqui e fail-open: nao existe
        resultado Ok=true sem API confirmada com sucesso.
      - LIMITACAO HONESTA (declarada, nao escondida): a atribuicao acontece
        DEPOIS do start do filho (o .NET nao expoe CREATE_SUSPENDED), entao ha
        uma janela entre create e assign em que um neto ja criado fica de fora
        do job. Add-RuntimeJobProcess reporta Assigned honesto e o chamador
        decide. O caminho PRIMARY de parada continua sendo o gracil (CLI do
        servico); este e backstop bounded.

    Nao mata PID fora do job. Nao toca flags do repositorio. Nao le 49374.
#>

$ErrorActionPreference = 'Stop'

$RuntimeJobCs = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class RuntimeJobNative
{
  public const int JOB_OBJECT_BASIC_PROCESS_ID_LIST = 3;
  public const int JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9;
  public const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
  public const uint JOB_OBJECT_LIMIT_BREAKAWAY_OK = 0x00000800;
  public const uint JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK = 0x00001000;
  public const int ERROR_MORE_DATA = 234;
  public const int ERROR_INSUFFICIENT_BUFFER = 122;

  [StructLayout(LayoutKind.Sequential)]
  public struct JobBasicLimitInformation
  {
    public Int64 PerProcessUserTimeLimit;
    public Int64 PerJobUserTimeLimit;
    public uint LimitFlags;
    public UIntPtr MinimumWorkingSetSize;
    public UIntPtr MaximumWorkingSetSize;
    public uint ActiveProcessLimit;
    public UIntPtr Affinity;
    public uint PriorityClass;
    public uint SchedulingClass;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct IoCounters
  {
    public UInt64 ReadOperationCount;
    public UInt64 WriteOperationCount;
    public UInt64 OtherOperationCount;
    public UInt64 ReadTransferCount;
    public UInt64 WriteTransferCount;
    public UInt64 OtherTransferCount;
  }

  [StructLayout(LayoutKind.Sequential)]
  public struct JobExtendedLimitInformation
  {
    public JobBasicLimitInformation BasicLimitInformation;
    public IoCounters IoInfo;
    public UIntPtr ProcessMemoryLimit;
    public UIntPtr JobMemoryLimit;
    public UIntPtr PeakProcessMemoryUsed;
    public UIntPtr PeakJobMemoryUsed;
  }

  [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "CreateJobObjectW", CharSet = CharSet.Unicode)]
  private static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);

  [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "SetInformationJobObject")]
  private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint infoLength);

  [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "QueryInformationJobObject")]
  private static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint infoLength, out uint returnLength);

  [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "AssignProcessToJobObject")]
  private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

  [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "TerminateJobObject")]
  private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

  [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "CloseHandle")]
  private static extern bool CloseHandle(IntPtr handle);

  public static int LastError()
  {
    return Marshal.GetLastWin32Error();
  }

  public static IntPtr CreateJob(string name)
  {
    return CreateJobObjectW(IntPtr.Zero, name);
  }

  // Zera a struct inteira e escreve SOMENTE as flags pedidas: nenhum outro
  // limite (memoria, quantidade, prioridade) e introduzido por engano.
  public static bool SetLimits(IntPtr job, uint flags)
  {
    int size = Marshal.SizeOf(typeof(JobExtendedLimitInformation));
    IntPtr buf = Marshal.AllocHGlobal(size);
    try
    {
      for (int i = 0; i < size; i += 4) { Marshal.WriteInt32(buf, i, 0); }
      JobExtendedLimitInformation info = new JobExtendedLimitInformation();
      info.BasicLimitInformation.LimitFlags = flags;
      Marshal.StructureToPtr(info, buf, false);
      return SetInformationJobObject(job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, buf, (uint)size);
    }
    finally
    {
      Marshal.FreeHGlobal(buf);
    }
  }

  public static bool QueryLimitFlags(IntPtr job, out uint flags)
  {
    flags = 0;
    int size = Marshal.SizeOf(typeof(JobExtendedLimitInformation));
    IntPtr buf = Marshal.AllocHGlobal(size);
    try
    {
      for (int i = 0; i < size; i += 4) { Marshal.WriteInt32(buf, i, 0); }
      uint ret = 0;
      if (!QueryInformationJobObject(job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, buf, (uint)size, out ret)) { return false; }
      JobExtendedLimitInformation info = (JobExtendedLimitInformation)Marshal.PtrToStructure(buf, typeof(JobExtendedLimitInformation));
      flags = info.BasicLimitInformation.LimitFlags;
      return true;
    }
    finally
    {
      Marshal.FreeHGlobal(buf);
    }
  }

  public static bool Assign(IntPtr job, IntPtr process)
  {
    return AssignProcessToJobObject(job, process);
  }

  public static bool Terminate(IntPtr job, uint exitCode)
  {
    return TerminateJobObject(job, exitCode);
  }

  public static bool Close(IntPtr handle)
  {
    return CloseHandle(handle);
  }

  // Le N slots de PID a partir de buf (8 bytes de header) e descarta slots
  // vazios (PID 0 = slot nunca preenchido pelo SO). Shared pelos caminhos de
  // sucesso e de overflow para que os dois leiam EXATAMENTE o mesmo formato.
  private static int[] ReadSlots(IntPtr buf, int n, int stride)
  {
    List<int> outPids = new List<int>();
    for (int i = 0; i < n; i++)
    {
      IntPtr slot = new IntPtr(buf.ToInt64() + 8 + (i * stride));
      int v = (int)Marshal.ReadIntPtr(slot).ToInt64();
      if (v > 0) { outPids.Add(v); }
    }
    return outPids.ToArray();
  }

  // Enumeracao BOUNDED dos PIDs do job (JobObjectBasicProcessIdList).
  // Retorna null apenas em falha DURA de API (o chamador vira resultado
  // estruturado). Excesso do teto vira lista parcial + truncated=true, com
  // contadores lidos do buffer da MESMA consulta (FIX2/G1).
  public static int[] QueryMemberPids(IntPtr job, int cap, out uint assigned, out uint listed, out bool truncated)
  {
    assigned = 0;
    listed = 0;
    truncated = false;
    if (cap <= 0) { cap = 1; }
    int stride = IntPtr.Size;
    // O buffer precisa comportar pelo menos UM slot de PID: um buffer so com o
    // cabecalho (8 bytes) falha com ERROR_BAD_LENGTH mesmo em job vazio.
    int hdrSize = 8 + stride;
    IntPtr hdr = Marshal.AllocHGlobal(hdrSize);
    try
    {
      for (int i = 0; i < hdrSize; i += 4) { Marshal.WriteInt32(hdr, i, 0); }
      uint retLen = 0;
      bool ok = QueryInformationJobObject(job, JOB_OBJECT_BASIC_PROCESS_ID_LIST, hdr, (uint)hdrSize, out retLen);
      if (!ok)
      {
        int err = Marshal.GetLastWin32Error();
        if ((err != ERROR_MORE_DATA) && (err != ERROR_INSUFFICIENT_BUFFER)) { return null; }
      }
      assigned = (uint)Marshal.ReadInt32(hdr, 0);
      listed = (uint)Marshal.ReadInt32(hdr, 4);
      if (assigned == 0) { return new int[0]; }
      if (assigned > (uint)cap) { truncated = true; }
      int want = (int)assigned;
      if (want > cap) { want = cap; }
      int bytes = 8 + (want * stride);
      IntPtr buf = Marshal.AllocHGlobal(bytes);
      try
      {
        for (int i = 0; i < bytes; i += 4) { Marshal.WriteInt32(buf, i, 0); }
        uint ret2 = 0;
        bool ok2 = QueryInformationJobObject(job, JOB_OBJECT_BASIC_PROCESS_ID_LIST, buf, (uint)bytes, out ret2);
        if (!ok2)
        {
          int err2 = Marshal.GetLastWin32Error();
          if ((err2 == ERROR_MORE_DATA) || (err2 == ERROR_INSUFFICIENT_BUFFER))
          {
            // FIX3/H-A: overflow. Os contadores DEVEM vir do SEGUNDO buffer, o
            // unico com o tamanho pedido: os contadores do probe de 1 slot
            // descrevem aquele probe e NAO esta consulta. Atribuicao
            // INCONDICIONAL (nunca "se > 0": um header legitimately zerado
            // seria preservado do probe e nao desta consulta).
            // Assigned e o CONTADOR REAL do SO e nao e rebaixado ao cap: com 3
            // membros e cap=1 devolve Assigned=3 + 1 PID. O cap limita SO a
            // quantidade de slots extraidos, nunca o contador.
            assigned = (uint)Marshal.ReadInt32(buf, 0);
            listed = (uint)Marshal.ReadInt32(buf, 4);
            truncated = true;
            int n2 = (int)listed;
            if (n2 > want) { n2 = want; }
            return ReadSlots(buf, n2, stride);
          }
          return null;
        }
        assigned = (uint)Marshal.ReadInt32(buf, 0);
        listed = (uint)Marshal.ReadInt32(buf, 4);
        int n = (int)listed;
        if (n > want) { n = want; truncated = true; }
        return ReadSlots(buf, n, stride);
      }
      finally
      {
        Marshal.FreeHGlobal(buf);
      }
    }
    finally
    {
      Marshal.FreeHGlobal(hdr);
    }
  }
}
'@
if (-not ([System.Management.Automation.PSTypeName]'RuntimeJobNative').Type) {
  Add-Type -TypeDefinition $RuntimeJobCs -Language CSharp
}

function Get-RuntimeJobMemberCap {
  param([int]$Cap = 0)
  if ($Cap -gt 0) { return $Cap }
  return 256
}

function Get-RuntimeJobHandle {
  # Resolve o handle do job sem tocar API. Retorna Ok=false (nunca excecao)
  # para job nulo, fechado ou sem handle utilizavel.
  param($Job = $null)
  if ($null -eq $Job) { return @{ Ok = $false; Handle = [IntPtr]::Zero; Reason = 'job ausente (nulo)' } }
  $closed = $true
  try {
    if ($Job -is [System.Collections.IDictionary]) {
      if ($Job.Contains('Closed')) { $closed = [bool]$Job['Closed'] }
    }
  }
  catch { $closed = $true }
  if ($closed) { return @{ Ok = $false; Handle = [IntPtr]::Zero; Reason = 'job marcado como fechado (handle nao utilizavel)' } }
  $h = [IntPtr]::Zero
  try {
    if ($Job -is [System.Collections.IDictionary]) { $h = [IntPtr]$Job['Handle'] }
    else { $h = [IntPtr]$Job.Handle }
  }
  catch { $h = [IntPtr]::Zero }
  if ($h -eq [IntPtr]::Zero) { return @{ Ok = $false; Handle = [IntPtr]::Zero; Reason = 'job sem handle (zero)' } }
  return @{ Ok = $true; Handle = $h; Reason = '' }
}

function New-RuntimeJobObject {
  # Cria o job e seta SOMENTE KILL_ON_JOB_CLOSE. Breakaway NAO e habilitado.
  # -NoKillOnClose (RR-P26-JOB-WIRING): cria o job SEM
  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE, ou seja, Close-RuntimeJobObject passa
  # a ser INERTE e a UNICA acao letal da lib e TerminateJobObject. O default
  # (sem o switch) permanece EXATAMENTE o de sempre: KILL_ON_JOB_CLOSE com
  # close letal. Quem usa o switch e o enforcement do watchdog, porque um
  # REFUSED (nada morto, deadline/tree recusado) NUNCA pode matar o processo
  # que ele reporta como nao morto: ali o Terminate e o unico ato letal, e ele
  # so roda no caminho que de fato matou.
  param([string]$Name = '', [switch]$NoKillOnClose)
  $res = @{ Ok = $false; Handle = [IntPtr]::Zero; Closed = $true; Reason = ''; Api = ''; LimitFlags = [uint32]0; KillOnClose = $false; Name = '' }
  if (-not [string]::IsNullOrWhiteSpace($Name)) {
    if ($Name -notmatch '\A[A-Za-z0-9_\-\.\\]+\z') {
      $res.Api = 'CreateJobObject'
      $res.Reason = 'nome de job com charset invalido (recusado antes da API)'
      return $res
    }
  }
  $h = [IntPtr]::Zero
  try {
    if ([string]::IsNullOrWhiteSpace($Name)) {
      $h = [RuntimeJobNative]::CreateJob([NullString]::Value)
    }
    else {
      $h = [RuntimeJobNative]::CreateJob($Name)
    }
  }
  catch {
    $res.Api = 'CreateJobObject'
    $res.Reason = ('excecao na seam (convertida): ' + $_.Exception.Message)
    return $res
  }
  $err = 0
  try { $err = [int][RuntimeJobNative]::LastError() } catch { $err = -1 }
  if ($h -eq [IntPtr]::Zero) {
    $res.Api = 'CreateJobObject'
    $res.Reason = ('CreateJobObjectW falhou (win32=' + $err + ')')
    return $res
  }
  $setOk = $false
  $limitFlags = [uint32]0x00002000
  if ($NoKillOnClose) { $limitFlags = [uint32]0 }
  try { $setOk = [bool][RuntimeJobNative]::SetLimits($h, $limitFlags) }
  catch {
    $res.Handle = $h
    $res.Closed = $false
    $res.Api = 'SetInformationJobObject'
    $res.Reason = ('excecao na seam (convertida): ' + $_.Exception.Message)
    return $res
  }
  if (-not $setOk) {
    $err2 = 0
    try { $err2 = [int][RuntimeJobNative]::LastError() } catch { $err2 = -1 }
    try { [void][RuntimeJobNative]::Close($h) } catch { }
    $res.Api = 'SetInformationJobObject'
    $res.Reason = ('SetInformationJobObject falhou (win32=' + $err2 + '); handle fechado, job inexistente')
    return $res
  }
  $res.Ok = $true
  $res.Handle = $h
  $res.Closed = $false
  $res.LimitFlags = $limitFlags
  $res.KillOnClose = (($limitFlags -band [uint32]0x00002000) -eq [uint32]0x00002000)
  $res.Api = ''
  if ($NoKillOnClose) {
    $res.Reason = 'job criado SEM KILL_ON_JOB_CLOSE (close inerte; unico ato letal e TerminateJobObject); breakaway NAO habilitado'
  }
  else {
    $res.Reason = 'job criado com KILL_ON_JOB_CLOSE; breakaway NAO habilitado'
  }
  $res.Name = [string]$Name
  return $res
}

function Get-RuntimeJobLimitFlags {
  # Prova de breakaway negado (query das flags efetivas do job).
  param($Job = $null)
  $res = @{ Ok = $false; LimitFlags = [uint32]0; KillOnClose = $false; BreakawayOk = $false; SilentBreakawayOk = $false; Reason = ''; Api = '' }
  $hv = Get-RuntimeJobHandle -Job $Job
  if (-not [bool]$hv.Ok) { $res.Api = 'QueryInformationJobObject'; $res.Reason = [string]$hv.Reason; return $res }
  $lf = [uint32]0
  $ok = $false
  try { $ok = [bool][RuntimeJobNative]::QueryLimitFlags($hv.Handle, [ref]$lf) }
  catch {
    $res.Api = 'QueryInformationJobObject'
    $res.Reason = ('excecao na seam (convertida): ' + $_.Exception.Message)
    return $res
  }
  if (-not $ok) {
    $err = 0
    try { $err = [int][RuntimeJobNative]::LastError() } catch { $err = -1 }
    $res.Api = 'QueryInformationJobObject'
    $res.Reason = ('QueryInformationJobObject(ExtendedLimitInformation) falhou (win32=' + $err + ')')
    return $res
  }
  $res.Ok = $true
  $res.LimitFlags = $lf
  $res.KillOnClose = (($lf -band [uint32]0x00002000) -eq [uint32]0x00002000)
  $res.BreakawayOk = (($lf -band [uint32]0x00000800) -eq [uint32]0x00000800)
  $res.SilentBreakawayOk = (($lf -band [uint32]0x00001000) -eq [uint32]0x00001000)
  $res.Reason = 'flags lidas por QueryInformationJobObject'
  return $res
}

function Add-RuntimeJobProcess {
  # AssignProcessToJobObject. CONTRATO PUBLICO (RR-P22-JOB-OBJECTS-FIX1 F1):
  # a atribuicao EXIGE o System.Diagnostics.Process retido do spawn PROPRIO.
  # Nao existe caminho publico por PID: OpenProcess por PID nao carrega prova
  # de ownership nem de creation-time, entao um PID reciclado faria a lib
  # atribuir (e depois encerrar) um processo TERCEIRO. O handle do .NET
  # Process e o objeto do kernel real, imune a PID-reuse. Handle indisponivel
  # (processo ja saiu, sem permissao, tipo invalido) => recusa estruturada
  # {Ok=false; Reason}, nunca excecao e nunca atribuicao por PID.
  param(
    [Parameter(Mandatory = $true)]$Job,
    $Process = $null
  )
  $res = @{ Ok = $false; Pid = 0; Api = ''; Reason = ''; ViaManagedHandle = $false }
  $hv = Get-RuntimeJobHandle -Job $Job
  if (-not [bool]$hv.Ok) { $res.Api = 'AssignProcessToJobObject'; $res.Reason = [string]$hv.Reason; return $res }
  if ($null -eq $Process) {
    $res.Api = 'AssignProcessToJobObject'
    $res.Reason = 'recusado: atribuicao exige o System.Diagnostics.Process do spawn proprio; PID nu nunca atribui (sem prova de ownership/creation-time)'
    return $res
  }
  if (-not ($Process -is [System.Diagnostics.Process])) {
    $res.Api = 'AssignProcessToJobObject'
    $res.Reason = ('recusado: -Process deve ser System.Diagnostics.Process (obtido ' + $Process.GetType().FullName + '); PID nu nunca atribui')
    return $res
  }
  $targetPid = 0
  try { $targetPid = [int]$Process.Id } catch { $targetPid = 0 }
  if ($targetPid -gt 0) { $res.Pid = $targetPid }
  # Defesa de hosts: o processo desta lib jamais entra no proprio job (encerrar
  # o host seria falha do backstop, nao contencao).
  if ($targetPid -gt 0) {
    try {
      if ($targetPid -eq [int]$PID) {
        $res.Api = 'AssignProcessToJobObject'
        $res.Reason = 'recusado: o processo atual (host) jamais entra em job (matar o host nao e contencao)'
        return $res
      }
    }
    catch { }
  }
  $hProc = [IntPtr]::Zero
  try {
    $raw = $Process.Handle
    if ($raw -ne $null) { $hProc = [IntPtr]$raw; $res.ViaManagedHandle = $true }
  }
  catch { $hProc = [IntPtr]::Zero }
  if ($hProc -eq [IntPtr]::Zero) {
    $res.Api = 'Process.Handle'
    $res.Reason = 'handle do .NET Process indisponivel (processo ja saiu ou sem permissao): recusa fail-closed, sem atribuicao por PID'
    return $res
  }
  $ok = $false
  try { $ok = [bool][RuntimeJobNative]::Assign($hv.Handle, $hProc) }
  catch {
    $res.Api = 'AssignProcessToJobObject'
    $res.Reason = ('excecao na seam (convertida): ' + $_.Exception.Message)
    return $res
  }
  if (-not $ok) {
    $err2 = 0
    try { $err2 = [int][RuntimeJobNative]::LastError() } catch { $err2 = -1 }
    $res.Api = 'AssignProcessToJobObject'
    $res.Reason = ('AssignProcessToJobObject falhou (win32=' + $err2 + ')')
    return $res
  }
  $res.Ok = $true
  $res.Reason = 'processo atribuido ao job via handle do spawn proprio (membership por arvore de criacao; imune a PID-reuse)'
  return $res
}

function Attach-RuntimeJobVerifiedProcess {
  # RR-P26-JOB-WIRING: AssignProcessToJobObject para uma instancia JA
  # PROVADA pelo CHAMADOR (o enforcement do watchdog), com re-verificacao
  # barata ANTES da atribuicao. Diferencas para Add-RuntimeJobProcess
  # (que permanece INTACTO e e o caminho de spawn proprio):
  #   - exige a IDENTIDADE (ticks de criacao em UTC) que o chamador provou:
  #     o seam compara com o StartTime lido da MESMA instancia pinada; sem
  #     identidade informada => recusa fail-closed (nada e atribuido).
  #   - exige LIVENESS pela propria instancia (HasExited -eq $false): uma
  #     instancia morta nao entra em job (atribuir um processo que ja saiu seria atribuicao sem prova).
  #   - NUNCA abre handle por PID: a atribuicao real e delegada ao
  #     Add-RuntimeJobProcess, que usa o handle JA retido do .NET (imune a
  #     PID-reuse). Sem OpenProcess, sem Get-Process por PID.
  #   - recusa o processo ATUAL (host) antes de qualquer API.
  # Resultado estruturado, NUNCA excecao atravessando a seam; nada aqui e
  # fail-open (Ok=true so com AssignProcessToJobObject confirmado).
  param(
    [Parameter(Mandatory = $true)]$Job,
    $Instance = $null,
    [long]$ExpectedCreationTicks = 0,
    [long]$ToleranceTicks = 0
  )
  $res = @{ Ok = $false; Pid = 0; Api = ''; Reason = ''; ViaManagedHandle = $false; InstanceLive = $false; IdentityVerified = $false }
  try {
    $hv = Get-RuntimeJobHandle -Job $Job
    if (-not [bool]$hv.Ok) { $res.Api = 'AssignProcessToJobObject'; $res.Reason = [string]$hv.Reason; return $res }
    if ($null -eq $Instance) {
      $res.Api = 'AssignProcessToJobObject'
      $res.Reason = 'recusado: atribuicao verificada exige a instancia System.Diagnostics.Process provada pelo chamador (nunca PID nu)'
      return $res
    }
    if (-not ($Instance -is [System.Diagnostics.Process])) {
      $res.Api = 'AssignProcessToJobObject'
      $res.Reason = ('recusado: -Instance deve ser System.Diagnostics.Process (obtido ' + $Instance.GetType().FullName + '); PID nu nunca atribui')
      return $res
    }
    $targetPid = 0
    try { $targetPid = [int]$Instance.Id } catch { $targetPid = 0 }
    if ($targetPid -gt 0) { $res.Pid = $targetPid }
    if (($targetPid -le 0) -or ($targetPid -eq [int]$PID)) {
      $res.Api = 'AssignProcessToJobObject'
      $res.Reason = 'recusado: o processo atual (host) jamais entra em job (matar o host nao e contencao)'
      return $res
    }
    if ([long]$ExpectedCreationTicks -le 0) {
      $res.Api = 'AssignProcessToJobObject'
      $res.Reason = 'recusado: identidade nao informada (ExpectedCreationTicks<=0); provavel divergencia de identidade, sem atribuicao'
      return $res
    }
    $exited = $false
    try { $exited = [bool]$Instance.HasExited } catch { $exited = $true }
    if ($exited) {
      $res.Api = 'AssignProcessToJobObject'
      $res.Reason = 'recusado: instancia provada ja saiu (liveness pela propria instancia falhou); sem atribuicao'
      return $res
    }
    $res.InstanceLive = $true
    $liveTicks = 0
    try { $liveTicks = ([long](([DateTime]$Instance.StartTime).ToUniversalTime().Ticks)) } catch { $liveTicks = 0 }
    if ($liveTicks -le 0) {
      $res.Api = 'AssignProcessToJobObject'
      $res.Reason = 'recusado: creation-time ilegivel na instancia provada; sem atribuicao'
      return $res
    }
    $skew = ($liveTicks - [long]$ExpectedCreationTicks)
    if ($skew -lt 0) { $skew = -$skew }
    if ($skew -gt [long]$ToleranceTicks) {
      $res.Api = 'AssignProcessToJobObject'
      $res.Reason = ('recusado: divergencia de identidade (instancia provada difere da identidade esperada em ' + $skew + ' ticks, tolerancia ' + [long]$ToleranceTicks + '); sem atribuicao')
      return $res
    }
    $res.IdentityVerified = $true
    # Delegacao: a atribuicao real continua sendo a de Add-RuntimeJobProcess
    # (handle retido do spawn proprio). Este seam NAO abre handle por PID.
    $add = Add-RuntimeJobProcess -Job $Job -Process $Instance
    $res.Ok = [bool]$add.Ok
    $res.Api = [string]$add.Api
    $res.Reason = [string]$add.Reason
    $res.ViaManagedHandle = [bool]$add.ViaManagedHandle
    if ([bool]$add.Ok) {
      $res.Reason = ('processo verificado atribuido ao job via handle retido da instancia provada (membership por arvore de criacao; imune a PID-reuse); ' + [string]$add.Reason)
    }
    else {
      $res.IdentityVerified = $false
    }
    return $res
  }
  catch {
    $res.Ok = $false
    $res.Api = 'AssignProcessToJobObject'
    $res.Reason = ('excecao na seam (convertida): ' + $_.Exception.Message)
    return $res
  }
}

function Get-RuntimeJobMemberPids {
  # QueryInformationJobObject(JobObjectBasicProcessIdList), enumeracao
  # BOUNDED. Excesso do teto => Truncated=true com lista parcial (nunca excecao).
  param($Job = $null, [int]$Cap = 0)
  $capUsed = Get-RuntimeJobMemberCap -Cap $Cap
  $res = @{ Ok = $false; Pids = @(); Count = 0; Assigned = 0; Truncated = $false; Cap = $capUsed; Reason = ''; Api = '' }
  $hv = Get-RuntimeJobHandle -Job $Job
  if (-not [bool]$hv.Ok) { $res.Api = 'QueryInformationJobObject'; $res.Reason = [string]$hv.Reason; return $res }
  $assigned = [uint32]0
  $listed = [uint32]0
  $truncated = $false
  $pids = $null
  try { $pids = [RuntimeJobNative]::QueryMemberPids($hv.Handle, $capUsed, [ref]$assigned, [ref]$listed, [ref]$truncated) }
  catch { $pids = $null }
  if ($null -eq $pids) {
    $err = 0
    try { $err = [int][RuntimeJobNative]::LastError() } catch { $err = -1 }
    $res.Api = 'QueryInformationJobObject'
    $res.Reason = ('QueryInformationJobObject(BasicProcessIdList) falhou (win32=' + $err + ')')
    return $res
  }
  $res.Ok = $true
  $res.Pids = @($pids)
  $res.Count = @($pids).Count
  $res.Assigned = [int]$assigned
  $res.Truncated = [bool]$truncated
  $res.Reason = ('membros=' + @($pids).Count + ' atribuidos=' + [int]$assigned + ' truncado=' + [bool]$truncated)
  return $res
}

function Stop-RuntimeJobObject {
  # TerminateJobObject + settlement BOUNDED por deadline ABSOLUTO (polling do
  # member list, mesmo padrao de deadline da P22).
  # FIX1 F3: cada espera e min(PollMs, tempo restante ate o deadline) e PollMs
  # tem TETO, entao TimeoutMs=100 com PollMs=60000 retorna perto de 100ms em
  # vez de bloquear ~60s. FIX1 F4: falha de consulta no settlement NAO e
  # sobrescrita por Ok=true: o resultado final e Ok=false com Api/Reason da
  # consulta, Terminated preservado, Truncated nunca sobrescrito.
  param(
    [Parameter(Mandatory = $true)]$Job,
    [int]$TimeoutMs = 15000,
    [int]$PollMs = 250,
    [int]$Cap = 0,
    [switch]$FaultInjectQueryAfterTerminate,
    [switch]$FaultInjectSkipTerminate
  )
  # FIX2/G2: os dois switches de injecao existem SO para exercitar o settlement
  # sem binario de servico; NENHUM caminho de producao os liga.
  #   -FaultInjectQueryAfterTerminate: zera o handle do job ANTES da primeira
  #     consulta de settlement, de modo que APENAS as consultas falham e o
  #     Terminate (que ja rodou) fica preservado como fato.
  #   -FaultInjectSkipTerminate: nao chama TerminateJobObject, para que um
  #     membro REAL permaneca vivo durante as esperas e a aritmetica de
  #     deadline (min(PollMs, restante)) seja observavel de verdade.
  $capUsed = Get-RuntimeJobMemberCap -Cap $Cap
  $res = @{ Ok = $false; Terminated = $false; Settled = $false; Remaining = 0; ElapsedMs = 0; DeadlineMs = $TimeoutMs; PollCount = 0; Truncated = $false; QueryFailed = $false; Reason = ''; Api = '' }
  $hv = Get-RuntimeJobHandle -Job $Job
  if (-not [bool]$hv.Ok) { $res.Api = 'TerminateJobObject'; $res.Reason = [string]$hv.Reason; return $res }
  if ($PollMs -lt 1) { $PollMs = 1 }
  if ($PollMs -gt 2000) { $PollMs = 2000 }
  $started = [DateTime]::UtcNow
  $deadline = $started.AddMilliseconds($TimeoutMs)
  if ($FaultInjectSkipTerminate) {
    # Fix2/G2: sem Terminate, o membro REAL continua vivo, e o laco de
    # settlement realmente espera ate o deadline (aritmetica observavel).
    $res.Terminated = $false
  }
  else {
    $ok = $false
    try { $ok = [bool][RuntimeJobNative]::Terminate($hv.Handle, [uint32]1) }
    catch {
      $res.Api = 'TerminateJobObject'
      $res.Reason = ('excecao na seam (convertida): ' + $_.Exception.Message)
      return $res
    }
  }
  if ((-not $FaultInjectSkipTerminate) -and (-not $ok)) {
    $err = 0
    try { $err = [int][RuntimeJobNative]::LastError() } catch { $err = -1 }
    $res.Api = 'TerminateJobObject'
    $res.Reason = ('TerminateJobObject falhou (win32=' + $err + '); nada encerrado por esta chamada')
    $res.ElapsedMs = [long]([DateTime]::UtcNow - $started).TotalMilliseconds
    return $res
  }
  if ($FaultInjectSkipTerminate) { $res.Terminated = $false } else { $res.Terminated = $true }
  $remaining = -1
  $settled = $false
  $truncated = $false
  $queryFailed = $false
  $queryApi = ''
  $queryReason = ''
  $polls = 0
  # FIX3/H-E: a injecao de falha de consulta NAO destroi a referencia do handle
  # nativo. Um dicionario local (handle zero) e usado SO nas chamadas de
  # consulta do settlement; o job real permanece integro e fechavel no finally
  # (zeroar $Job['Handle'] fazia o CloseHandle final fechar zero e o Job
  # Object VAZAR a cada chamada de teste).
  $queryJob = $Job
  if ($FaultInjectQueryAfterTerminate) {
    $queryJob = @{ Ok = $true; Handle = [IntPtr]::Zero; Closed = $false }
  }
  while ($true) {
    $m = Get-RuntimeJobMemberPids -Job $queryJob -Cap $capUsed
    if (-not [bool]$m.Ok) {
      # FIX1 F4: settlement NAO comprovado e a CONSULTA falhou. Propaga a falha
      # (fail-closed): nunca afirmar Ok=true nem Truncated como se fosse
      # truncamento de lista.
      $queryFailed = $true
      $queryApi = [string]$m.Api
      $queryReason = [string]$m.Reason
      break
    }
    $polls += 1
    $remaining = [int]$m.Assigned
    $truncated = [bool]$m.Truncated
    if ($remaining -le 0) { $settled = $true; break }
    $remainingMs = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
    if ($remainingMs -le 0) { break }
    # FIX1 F3: nunca dorme alem do deadline absoluto.
    $sleepMs = $PollMs
    if ($sleepMs -gt $remainingMs) { $sleepMs = $remainingMs }
    if ($sleepMs -lt 1) { $sleepMs = 1 }
    Start-Sleep -Milliseconds $sleepMs
  }
  $res.Settled = $settled
  $res.Remaining = $remaining
  # FIX1 F4: Truncated reflete a ultima consulta VALIDA; nao e usado como
  # atalho para "consulta falhou".
  if (-not $queryFailed) { $res.Truncated = $truncated }
  $res.QueryFailed = $queryFailed
  $res.PollCount = $polls
  $res.ElapsedMs = [long]([DateTime]::UtcNow - $started).TotalMilliseconds
  if ($queryFailed) {
    $res.Ok = $false
    $res.Api = $queryApi
    $res.Reason = ('settlement NAO comprovado: consulta de membros falhou (api=' + $queryApi + ' ' + $queryReason + '); terminate aplicado, membros restantes DESCONHECIDOS (fail-closed)')
    return $res
  }
  $res.Ok = $true
  if ($settled) {
    $res.Reason = ('job terminado e sem membros apos ' + [long]$res.ElapsedMs + 'ms (' + $polls + ' consulta(s))')
  }
  elseif ($FaultInjectSkipTerminate) {
    $res.Reason = ('settlement PENDENTE apos deadline ' + $TimeoutMs + 'ms (' + $polls + ' espera(s)); membros restantes=' + $remaining + ' (Terminate NAO aplicado: injecao de teste)')
  }
  else {
    $res.Reason = ('TerminateJobObject aplicado; membros restantes=' + $remaining + ' apos deadline ' + $TimeoutMs + 'ms (settlement PENDENTE)')
  }
  return $res
}

function Close-RuntimeJobObject {
  # CloseHandle: com KILL_ON_JOB_CLOSE, e o backstop final (fechar sem Stop
  # encerra os membros). Idempotente.
  param([Parameter(Mandatory = $true)]$Job)
  $res = @{ Ok = $false; Closed = $false; Reason = ''; Api = '' }
  if ($null -eq $Job) { $res.Api = 'CloseHandle'; $res.Reason = 'job ausente (nulo)'; return $res }
  $already = $false
  try {
    if (($Job -is [System.Collections.IDictionary]) -and $Job.Contains('Closed')) { $already = [bool]$Job['Closed'] }
  }
  catch { $already = $true }
  if ($already) { $res.Ok = $true; $res.Closed = $true; $res.Reason = 'job ja fechado (idempotente, sem API)'; return $res }
  $h = [IntPtr]::Zero
  try {
    if ($Job -is [System.Collections.IDictionary]) { $h = [IntPtr]$Job['Handle'] } else { $h = [IntPtr]$Job.Handle }
  }
  catch { $h = [IntPtr]::Zero }
  if ($h -eq [IntPtr]::Zero) {
    $res.Api = 'CloseHandle'
    $res.Reason = 'job sem handle (zero)'
    return $res
  }
  $ok = $false
  try { $ok = [bool][RuntimeJobNative]::Close($h) }
  catch {
    $res.Api = 'CloseHandle'
    $res.Reason = ('excecao na seam (convertida): ' + $_.Exception.Message)
    return $res
  }
  if (-not $ok) {
    $err = 0
    try { $err = [int][RuntimeJobNative]::LastError() } catch { $err = -1 }
    $res.Api = 'CloseHandle'
    $res.Reason = ('CloseHandle falhou (win32=' + $err + ')')
    return $res
  }
  try {
    if ($Job -is [System.Collections.IDictionary]) {
      $Job['Closed'] = $true
      $Job['Handle'] = [IntPtr]::Zero
    }
  }
  catch { }
  $res.Ok = $true
  $res.Closed = $true
  $res.Reason = 'handle fechado (KILL_ON_JOB_CLOSE: membros remanescentes encerrados pelo SO)'
  return $res
}