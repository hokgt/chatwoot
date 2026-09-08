// The Marine custom tools API client has been disabled to eliminate all direct
// outbound connectivity between Marine AI and ERP. Marine AI's only allowed
// outbound path is reading from the local marine_catalog PostgreSQL database via
// the read-only catalog connection. The backend custom_tools endpoints now
// return 404, so no client is exported here.
