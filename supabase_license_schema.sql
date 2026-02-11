-- ============================================
-- VEO3 INFINITY LICENSING SYSTEM - SUPABASE SCHEMA
-- ============================================
-- Run these commands in your Supabase SQL Editor

-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================
-- 1. LICENSES TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS licenses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    license_key VARCHAR(50) UNIQUE NOT NULL,
    customer_name VARCHAR(255),
    customer_email VARCHAR(255),
    max_devices INTEGER DEFAULT 1,
    expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
    is_active BOOLEAN DEFAULT true,
    notes TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ============================================
-- 2. LICENSE DEVICES TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS license_devices (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    license_id UUID REFERENCES licenses(id) ON DELETE CASCADE,
    device_id VARCHAR(255) NOT NULL,
    device_name VARCHAR(255),
    platform VARCHAR(50), -- windows, android, ios, macos, linux
    app_version VARCHAR(50),
    registered_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_seen_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    is_active BOOLEAN DEFAULT true,
    ip_address VARCHAR(50),
    UNIQUE(license_id, device_id)
);

-- ============================================
-- 3. LICENSE LOGS TABLE (Audit Trail)
-- ============================================
CREATE TABLE IF NOT EXISTS license_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    license_id UUID REFERENCES licenses(id) ON DELETE SET NULL,
    device_id VARCHAR(255),
    action VARCHAR(50) NOT NULL, -- 'validate', 'register', 'revoke', 'extend', 'login_attempt', 'expired'
    status VARCHAR(20) NOT NULL, -- 'success', 'failed', 'blocked'
    message TEXT,
    ip_address VARCHAR(50),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- ============================================
-- 4. ADMIN USERS TABLE (for web panel)
-- ============================================
CREATE TABLE IF NOT EXISTS admin_users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    username VARCHAR(100) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    is_active BOOLEAN DEFAULT true,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_login_at TIMESTAMP WITH TIME ZONE
);

-- ============================================
-- 5. APP SETTINGS TABLE
-- ============================================
CREATE TABLE IF NOT EXISTS app_settings (
    key VARCHAR(100) PRIMARY KEY,
    value TEXT NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Insert default settings
INSERT INTO app_settings (key, value) VALUES 
    ('app_name', 'VEO3 Infinity'),
    ('min_app_version', '1.0.0'),
    ('latest_version', '1.0.0'),
    ('download_url', 'https://github.com/yourrepo/veo3_infinity/releases/latest'),
    ('release_notes', 'Initial release'),
    ('license_check_interval_hours', '24'),
    ('offline_grace_period_days', '7')
ON CONFLICT (key) DO NOTHING;

-- ============================================
-- 6. INDEXES FOR PERFORMANCE
-- ============================================
CREATE INDEX IF NOT EXISTS idx_licenses_key ON licenses(license_key);
CREATE INDEX IF NOT EXISTS idx_licenses_active ON licenses(is_active);
CREATE INDEX IF NOT EXISTS idx_license_devices_license ON license_devices(license_id);
CREATE INDEX IF NOT EXISTS idx_license_devices_device ON license_devices(device_id);
CREATE INDEX IF NOT EXISTS idx_license_logs_license ON license_logs(license_id);
CREATE INDEX IF NOT EXISTS idx_license_logs_created ON license_logs(created_at);

-- ============================================
-- 7. AUTO-UPDATE TIMESTAMP FUNCTION
-- ============================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS licenses_updated_at ON licenses;
CREATE TRIGGER licenses_updated_at
    BEFORE UPDATE ON licenses
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at();

-- ============================================
-- 8. LICENSE VALIDATION FUNCTION
-- ============================================
CREATE OR REPLACE FUNCTION validate_license(
    p_license_key VARCHAR,
    p_device_id VARCHAR,
    p_device_name VARCHAR DEFAULT NULL,
    p_platform VARCHAR DEFAULT NULL,
    p_app_version VARCHAR DEFAULT NULL,
    p_ip_address VARCHAR DEFAULT NULL
)
RETURNS JSON AS $$
DECLARE
    v_license RECORD;
    v_device RECORD;
    v_device_count INTEGER;
    v_result JSON;
BEGIN
    -- Find the license
    SELECT * INTO v_license FROM licenses 
    WHERE license_key = p_license_key;
    
    -- License not found
    IF NOT FOUND THEN
        INSERT INTO license_logs (license_id, device_id, action, status, message, ip_address)
        VALUES (NULL, p_device_id, 'validate', 'failed', 'License key not found', p_ip_address);
        
        RETURN json_build_object(
            'valid', false,
            'error', 'INVALID_LICENSE',
            'message', 'License key not found'
        );
    END IF;
    
    -- License not active
    IF NOT v_license.is_active THEN
        INSERT INTO license_logs (license_id, device_id, action, status, message, ip_address)
        VALUES (v_license.id, p_device_id, 'validate', 'failed', 'License is deactivated', p_ip_address);
        
        RETURN json_build_object(
            'valid', false,
            'error', 'LICENSE_DEACTIVATED',
            'message', 'This license has been deactivated'
        );
    END IF;
    
    -- License expired
    IF v_license.expires_at < NOW() THEN
        INSERT INTO license_logs (license_id, device_id, action, status, message, ip_address)
        VALUES (v_license.id, p_device_id, 'expired', 'failed', 'License has expired', p_ip_address);
        
        RETURN json_build_object(
            'valid', false,
            'error', 'LICENSE_EXPIRED',
            'message', 'License has expired on ' || v_license.expires_at::TEXT,
            'expired_at', v_license.expires_at
        );
    END IF;
    
    -- Check if device is already registered
    SELECT * INTO v_device FROM license_devices 
    WHERE license_id = v_license.id AND device_id = p_device_id;
    
    IF FOUND THEN
        -- Device exists - check if active
        IF NOT v_device.is_active THEN
            INSERT INTO license_logs (license_id, device_id, action, status, message, ip_address)
            VALUES (v_license.id, p_device_id, 'validate', 'blocked', 'Device has been revoked', p_ip_address);
            
            RETURN json_build_object(
                'valid', false,
                'error', 'DEVICE_REVOKED',
                'message', 'This device has been revoked from the license'
            );
        END IF;
        
        -- Update last seen
        UPDATE license_devices 
        SET last_seen_at = NOW(), 
            app_version = COALESCE(p_app_version, app_version),
            ip_address = COALESCE(p_ip_address, ip_address)
        WHERE id = v_device.id;
        
        INSERT INTO license_logs (license_id, device_id, action, status, message, ip_address)
        VALUES (v_license.id, p_device_id, 'validate', 'success', 'Device validated', p_ip_address);
        
        RETURN json_build_object(
            'valid', true,
            'license_id', v_license.id,
            'expires_at', v_license.expires_at,
            'days_remaining', EXTRACT(DAY FROM (v_license.expires_at - NOW()))::INTEGER,
            'max_devices', v_license.max_devices,
            'customer_name', v_license.customer_name
        );
    ELSE
        -- New device - check device limit
        SELECT COUNT(*) INTO v_device_count FROM license_devices 
        WHERE license_id = v_license.id AND is_active = true;
        
        IF v_device_count >= v_license.max_devices THEN
            INSERT INTO license_logs (license_id, device_id, action, status, message, ip_address)
            VALUES (v_license.id, p_device_id, 'register', 'failed', 'Device limit reached', p_ip_address);
            
            RETURN json_build_object(
                'valid', false,
                'error', 'DEVICE_LIMIT_REACHED',
                'message', 'Maximum device limit (' || v_license.max_devices || ') reached. Contact support to add more devices.',
                'max_devices', v_license.max_devices,
                'active_devices', v_device_count
            );
        END IF;
        
        -- Register new device
        INSERT INTO license_devices (license_id, device_id, device_name, platform, app_version, ip_address)
        VALUES (v_license.id, p_device_id, p_device_name, p_platform, p_app_version, p_ip_address);
        
        INSERT INTO license_logs (license_id, device_id, action, status, message, ip_address)
        VALUES (v_license.id, p_device_id, 'register', 'success', 'New device registered', p_ip_address);
        
        RETURN json_build_object(
            'valid', true,
            'license_id', v_license.id,
            'expires_at', v_license.expires_at,
            'days_remaining', EXTRACT(DAY FROM (v_license.expires_at - NOW()))::INTEGER,
            'max_devices', v_license.max_devices,
            'customer_name', v_license.customer_name,
            'new_device', true
        );
    END IF;
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 9. HELPER FUNCTIONS
-- ============================================

-- Generate random license key
CREATE OR REPLACE FUNCTION generate_license_key()
RETURNS VARCHAR AS $$
DECLARE
    chars TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    result VARCHAR := '';
    i INTEGER;
BEGIN
    FOR i IN 1..4 LOOP
        IF i > 1 THEN
            result := result || '-';
        END IF;
        FOR j IN 1..4 LOOP
            result := result || substr(chars, floor(random() * length(chars) + 1)::int, 1);
        END LOOP;
    END LOOP;
    RETURN result;
END;
$$ LANGUAGE plpgsql;

-- Create license helper
CREATE OR REPLACE FUNCTION create_license(
    p_customer_name VARCHAR,
    p_customer_email VARCHAR DEFAULT NULL,
    p_max_devices INTEGER DEFAULT 1,
    p_duration_days INTEGER DEFAULT 365,
    p_notes TEXT DEFAULT NULL
)
RETURNS JSON AS $$
DECLARE
    v_license_key VARCHAR;
    v_license_id UUID;
BEGIN
    -- Generate unique license key
    LOOP
        v_license_key := generate_license_key();
        EXIT WHEN NOT EXISTS (SELECT 1 FROM licenses WHERE license_key = v_license_key);
    END LOOP;
    
    -- Insert license
    INSERT INTO licenses (license_key, customer_name, customer_email, max_devices, expires_at, notes)
    VALUES (v_license_key, p_customer_name, p_customer_email, p_max_devices, NOW() + (p_duration_days || ' days')::INTERVAL, p_notes)
    RETURNING id INTO v_license_id;
    
    RETURN json_build_object(
        'id', v_license_id,
        'license_key', v_license_key,
        'customer_name', p_customer_name,
        'max_devices', p_max_devices,
        'expires_at', NOW() + (p_duration_days || ' days')::INTERVAL
    );
END;
$$ LANGUAGE plpgsql;

-- ============================================
-- 10. ROW LEVEL SECURITY (Optional)
-- ============================================
-- Enable RLS if you want to restrict access
-- ALTER TABLE licenses ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE license_devices ENABLE ROW LEVEL SECURITY;
-- ALTER TABLE license_logs ENABLE ROW LEVEL SECURITY;

-- ============================================
-- 11. SAMPLE DATA (Optional - Remove in production)
-- ============================================
-- Create a test license
-- SELECT create_license('Test User', 'test@example.com', 3, 30, 'Test license');

-- ============================================
-- 12. VIEWS FOR ADMIN PANEL
-- ============================================
CREATE OR REPLACE VIEW license_overview AS
SELECT 
    l.id,
    l.license_key,
    l.customer_name,
    l.customer_email,
    l.max_devices,
    l.expires_at,
    l.is_active,
    l.created_at,
    CASE 
        WHEN l.expires_at < NOW() THEN 'expired'
        WHEN NOT l.is_active THEN 'deactivated'
        ELSE 'active'
    END as status,
    EXTRACT(DAY FROM (l.expires_at - NOW()))::INTEGER as days_remaining,
    COUNT(DISTINCT ld.id) FILTER (WHERE ld.is_active = true) as active_devices,
    MAX(ld.last_seen_at) as last_activity
FROM licenses l
LEFT JOIN license_devices ld ON l.id = ld.license_id
GROUP BY l.id;

-- ============================================
-- GRANT PERMISSIONS (adjust as needed)
-- ============================================
-- For anon/public access (API calls from app):
GRANT EXECUTE ON FUNCTION validate_license TO anon;
GRANT EXECUTE ON FUNCTION create_license TO anon;
GRANT SELECT ON app_settings TO anon;

-- For admin panel - anon key needs read/write access
GRANT SELECT ON licenses TO anon;
GRANT SELECT, INSERT, UPDATE ON licenses TO anon;
GRANT SELECT ON license_overview TO anon;
GRANT SELECT, UPDATE ON license_devices TO anon;
GRANT SELECT ON license_logs TO anon;

-- For authenticated/service role (full access):
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
