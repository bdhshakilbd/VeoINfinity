-- Fix permissions for VEO3 Licensing System
-- Run this in Supabase SQL Editor

-- Grant execute permissions on all functions to anon role
GRANT EXECUTE ON FUNCTION validate_license TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION create_license TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION generate_license_key TO anon, authenticated, service_role;

-- Grant permissions on all tables to anon role
GRANT ALL ON licenses TO anon, authenticated, service_role;
GRANT ALL ON license_devices TO anon, authenticated, service_role;
GRANT ALL ON license_logs TO anon, authenticated, service_role;
GRANT ALL ON admin_users TO anon, authenticated, service_role;
GRANT ALL ON app_settings TO anon, authenticated, service_role;

-- Grant permissions on the view
GRANT SELECT ON license_overview TO anon, authenticated, service_role;

-- Ensure RLS is disabled (since you want unrestricted access with anon key)
ALTER TABLE licenses DISABLE ROW LEVEL SECURITY;
ALTER TABLE license_devices DISABLE ROW LEVEL SECURITY;
ALTER TABLE license_logs DISABLE ROW LEVEL SECURITY;
ALTER TABLE admin_users DISABLE ROW LEVEL SECURITY;
ALTER TABLE app_settings DISABLE ROW LEVEL SECURITY;
