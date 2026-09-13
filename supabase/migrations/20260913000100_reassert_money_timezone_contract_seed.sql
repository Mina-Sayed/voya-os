-- Reassert immutable reference data for the money/timezone validation triggers.
-- This is idempotent so an existing local or managed database with missing
-- reference rows can recover without rebuilding tenant data.

INSERT INTO public.supported_currency_contract (code, minor_digits, display_name)
VALUES
  ('AED', 2, 'United Arab Emirates dirham'),
  ('BHD', 3, 'Bahraini dinar'),
  ('EGP', 2, 'Egyptian pound'),
  ('EUR', 2, 'Euro'),
  ('GBP', 2, 'Pound sterling'),
  ('IQD', 3, 'Iraqi dinar'),
  ('JOD', 3, 'Jordanian dinar'),
  ('JPY', 0, 'Japanese yen'),
  ('KWD', 3, 'Kuwaiti dinar'),
  ('LYD', 3, 'Libyan dinar'),
  ('MAD', 2, 'Moroccan dirham'),
  ('OMR', 3, 'Omani rial'),
  ('QAR', 2, 'Qatari riyal'),
  ('SAR', 2, 'Saudi riyal'),
  ('TND', 3, 'Tunisian dinar'),
  ('USD', 2, 'United States dollar')
ON CONFLICT (code) DO UPDATE
SET minor_digits = EXCLUDED.minor_digits,
    display_name = EXCLUDED.display_name;

INSERT INTO public.supported_timezone_contract (name)
VALUES
  ('UTC'),
  ('Africa/Cairo'),
  ('Africa/Casablanca'),
  ('Africa/Johannesburg'),
  ('Africa/Tripoli'),
  ('America/Chicago'),
  ('America/Los_Angeles'),
  ('America/New_York'),
  ('Asia/Amman'),
  ('Asia/Baghdad'),
  ('Asia/Beirut'),
  ('Asia/Dubai'),
  ('Asia/Kuwait'),
  ('Asia/Muscat'),
  ('Asia/Qatar'),
  ('Asia/Riyadh'),
  ('Europe/Berlin'),
  ('Europe/London'),
  ('Europe/Paris')
ON CONFLICT (name) DO NOTHING;