# CMU SIS Snapshot Controller

A configurable snapshot controller for Blackboard Learn utilizing our [PowerShell Module](https://github.com/cmichBb/sis-powershell) to interact with Learn.

This script is intended to be run periodically by a scheduled task, but could also be called manually.

Submits one or more feed files to Learn, monitors their progress, and (optionally) emails a report to specified addresses. Configurable log and archive retention.

## Version History

### v1.0

- Initial Public Release

## Installation & Prerequisites

This script can be placed at and run from any location, but does require the aforementioned [PowerShell Module](https://github.com/cmichBb/sis-powershell) to function. This script will Import the module, so if it is installed anywhere in `$env:PSModulePath` it will be loaded automatically.

## Usage

See the (slightly modified) `Get-Help` output below for usage instructions

	NAME
	    SIS_Snapshot_Controller.ps1
	    
	SYNOPSIS
	    A controller for submitting feed files to Blackboard Learn's SIS Integration Framework
	    
	SYNTAX
	    D:\Scripts\Blackboard\sis-controller\SIS_Snapshot_Controller.ps1 [[-ConfigFile] <String>] [<CommonParameters>]
	    
	    
	DESCRIPTION
	    Submits a set of one or more feed files to an SIS Integraion Endpoint on Blackboard Learn, monitors the status of 
	    those submissions, and optionally reports via email upon completion. Configurable via XML configuration file.
	    

	PARAMETERS
	    -ConfigFile <String>
	        The full path to the configuration file to use. Defaults to config.xml in the working directory.
	        
	        Required?                    false
	        Position?                    1
	        Default value                (Join-Path (Get-Location) "config.xml")
	        Accept pipeline input?       false
	        Accept wildcard characters?  false
	        
	    <CommonParameters>
	        This cmdlet supports the common parameters: Verbose, Debug,
	        ErrorAction, ErrorVariable, WarningAction, WarningVariable,
	        OutBuffer, PipelineVariable, and OutVariable. For more information, see 
	        about_CommonParameters (http://go.microsoft.com/fwlink/?LinkID=113216). 
	    
	    -------------------------- EXAMPLE 1 --------------------------
	    
	    C:\PS>.\SIS_Snapshot_Controller.ps1 -ConfigFile D:\SIS_Snapshot\config.xml
	    
	   -------------------------- EXAMPLE 2 --------------------------

	    C:\PS>.\SIS_Snapshot_Controller.ps1

	    This usage assumes a configuration file exists at the current location named "config.xml"

## Configuration

The included sample configuration file details the various configuration options for the script. Most of them will need to be changed from the default/example values.