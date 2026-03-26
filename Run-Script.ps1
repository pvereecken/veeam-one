## Enter your credentials to logon to Veeam ONE and create the billing report
$cred = Get-Credential
.\Get-VeeamONEBillingReport.ps1 -VeeamOneServer vone-server.domain.com -Credential $cred -SkipCertificateCheck