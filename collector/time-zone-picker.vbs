Option Explicit

Dim answer
answer = MsgBox( _
  "What time zone were these robot log timestamps taken in?" & vbCrLf & vbCrLf & _
  "Yes = UTC (most roboRIO logs)" & vbCrLf & _
  "No = Mountain / this laptop's local time", _
  vbYesNoCancel + vbQuestion, _
  "Marble Collector – Log Time Zone")

If answer = vbYes Then
  WScript.Echo "utc"
ElseIf answer = vbNo Then
  WScript.Echo "local"
Else
  WScript.Echo "cancel"
End If
