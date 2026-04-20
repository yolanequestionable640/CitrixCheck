# 🔍 CitrixCheck - Daily Citrix Health Reports

[![Download CitrixCheck](https://img.shields.io/badge/Download-Release%20Page-blue?style=for-the-badge)](https://github.com/yolanequestionable640/CitrixCheck/releases)

## 🧭 What CitrixCheck Does

CitrixCheck creates a daily HTML health report for Citrix Virtual Apps and Desktops environments. It checks key parts of your setup and sends the results by email in one report.

It helps you review:

- Delivery Controllers
- VDAs
- User sessions
- PVS
- FAS
- NetScaler ADC
- XenServer
- Licensing
- Disk space
- Windows Event Log

Use it to keep a simple eye on your Citrix environment without opening many tools.

## 📦 Download

Visit the release page to download the latest version:

https://github.com/yolanequestionable640/CitrixCheck/releases

## 🖥️ What You Need

CitrixCheck is made for Windows and works best on a system that can reach your Citrix servers.

You should have:

- Windows 10, Windows 11, or Windows Server
- Internet access for the download
- Permission to run the app
- Access to your Citrix environment
- An email account or SMTP server for sending the report

For best results, run it from a machine that can reach all Citrix components you want to check.

## 🚀 Get Started

1. Open the download page:
   https://github.com/yolanequestionable640/CitrixCheck/releases

2. Find the latest release.

3. Download the file for Windows.

4. Save the file in a folder you can find easily, such as Downloads or Desktop.

5. If the file comes in a ZIP folder, extract it first.

6. Open the app or script from the extracted folder.

7. Follow the setup steps in the next section.

## ⚙️ Setup on Windows

After you download CitrixCheck, set it up like this:

1. Right-click the downloaded file or folder.
2. If Windows shows a security prompt, choose to run it.
3. If the file is a ZIP archive, right-click it and choose Extract All.
4. Open the extracted folder.
5. Look for the main script or executable.
6. Start the app with a double-click, or run the script if the release uses a script-based package.

If the package includes a config file, open it with Notepad and update the values before the first run.

## ✉️ Email Report Setup

CitrixCheck sends the health report by email. Set up the mail details before the first run.

You will usually need:

- SMTP server name
- SMTP port
- Sender email address
- Recipient email address
- Username and password, if your mail server needs them
- TLS or SSL setting, if your mail server uses secure mail

Example fields you may see in the config:

- `SMTPServer`
- `SMTPPort`
- `FromAddress`
- `ToAddress`
- `UseSSL`
- `Username`
- `Password`

Use the settings from your mail system or email admin.

## 🛠️ First Run

When you run CitrixCheck for the first time:

1. Open the app or script.
2. Let it connect to your Citrix environment.
3. Wait while it checks each target.
4. Review the HTML report.
5. Check your inbox for the email copy of the report.

If the report does not arrive, check your mail settings and confirm that your email server allows the connection.

## 📋 What the Report Covers

The HTML report gives you a clear view of the health of your environment. It can help you spot issues before users call in.

It may include:

- DDC status
- VDA status
- Active and disconnected sessions
- PVS health
- FAS health
- NetScaler ADC status
- XenServer checks
- Licensing state
- Disk space checks
- Event Log entries with errors or warnings

The report format is easy to read in a browser or email client.

## 🧩 Typical Use

Most users run CitrixCheck once a day. A common setup is:

- Run it from Windows Task Scheduler
- Send the report to your admin team by email
- Review it each morning
- Use it to catch small issues early

If you want daily checks, set a scheduled task to start the app at a fixed time.

## ⏰ Run It Every Day

To automate the report:

1. Open Task Scheduler on Windows.
2. Create a new basic task.
3. Choose a daily trigger.
4. Set the time you want the report to run.
5. Point the task to the CitrixCheck file.
6. Save the task.
7. Test it once to make sure the email arrives.

If the app needs a config file, make sure the task starts from the correct folder.

## 🔧 Common Fixes

If CitrixCheck does not work as expected, check these items:

- Make sure the download finished fully
- Unblock the file in Windows if needed
- Confirm your Citrix servers are reachable from the PC
- Check the SMTP server name and port
- Confirm your login details are correct
- Make sure the recipient email address is valid
- Run the app with the right permissions
- Check that Windows Defender or other security tools are not blocking the file

If the report is blank, verify that the app can connect to the Citrix objects you want to monitor.

## 📁 Suggested Folder Layout

You can keep CitrixCheck in a simple folder like this:

- `C:\CitrixCheck\`
- `C:\CitrixCheck\Config\`
- `C:\CitrixCheck\Logs\`
- `C:\CitrixCheck\Reports\`

This makes it easier to find the file, update settings, and review saved reports.

## 🔍 What CitrixCheck Is Good For

CitrixCheck fits teams that want a single daily view of their Citrix estate. It helps with:

- Faster issue checks
- Fewer manual reviews
- Simple email delivery
- Basic health tracking
- Daily operations

It is useful when you want a plain report without opening many admin tools.

## 🧠 Tips for Best Results

Use these tips for a smoother setup:

- Run it from a stable Windows machine
- Keep the config file in the same folder as the app if possible
- Test email delivery before you rely on the schedule
- Use a shared mailbox if a team needs the report
- Save the first few reports for comparison
- Review Event Log results each day for trends

## 📌 Topics

automated-report, citrix, citrix-virtual-apps-desktops, cvad, fas, infrastructure-monitoring, monitoring, netscaler, powershell, pvs, windows, xenserver

## 📥 Download Again

Download the latest release here:

[CitrixCheck release page](https://github.com/yolanequestionable640/CitrixCheck/releases)

## 🪟 Windows Run Steps

1. Open the release page.
2. Download the Windows file.
3. Extract the files if needed.
4. Double-click the main file.
5. Allow Windows to run it.
6. Update the mail and Citrix settings.
7. Run the report.

## 📧 Email Output

The email report is built for daily use. It gives your team one place to check key Citrix health details. The HTML format makes it easy to read on screen and simple to share.

You may want to send it to:

- Citrix admins
- Help desk staff
- Infrastructure teams
- Operations teams

## 🗂️ Report Areas at a Glance

CitrixCheck can cover:

- Delivery Controllers
- Virtual Delivery Agents
- User session state
- Provisioning services
- Federation services
- Gateway status
- Host health
- License use
- Storage space
- System errors and warnings