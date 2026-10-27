CREATE TABLE IF NOT EXISTS public.instagram_accounts (
    id TEXT PRIMARY KEY,
    username TEXT,
    name TEXT,
    profile_pic_url TEXT,
    access_token TEXT,
    token_expires_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.instagram_conversations (
    id TEXT PRIMARY KEY,
    account_id TEXT REFERENCES public.instagram_accounts(id) ON DELETE CASCADE,
    participant_id TEXT NOT NULL,
    participant_username TEXT,
    last_message TEXT,
    last_message_time TIMESTAMPTZ,
    unread_count INT DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS public.instagram_messages (
    id TEXT PRIMARY KEY,
    conversation_id TEXT REFERENCES public.instagram_conversations(id) ON DELETE CASCADE,
    account_id TEXT REFERENCES public.instagram_accounts(id) ON DELETE CASCADE,
    sender_id TEXT NOT NULL,
    recipient_id TEXT NOT NULL,
    text TEXT,
    attachments JSONB DEFAULT '[]'::jsonb,
    is_echo BOOLEAN DEFAULT FALSE,
    raw_payload JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_ig_conv_account ON public.instagram_conversations(account_id);
CREATE INDEX IF NOT EXISTS idx_ig_conv_participant ON public.instagram_conversations(participant_id);
CREATE INDEX IF NOT EXISTS idx_ig_msg_conv ON public.instagram_messages(conversation_id);
CREATE INDEX IF NOT EXISTS idx_ig_msg_sender ON public.instagram_messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_ig_msg_recipient ON public.instagram_messages(recipient_id);
CREATE INDEX IF NOT EXISTS idx_ig_msg_created ON public.instagram_messages(created_at DESC);

ALTER TABLE public.instagram_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.instagram_conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.instagram_messages ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'Allow public read on instagram_accounts') THEN
        CREATE POLICY "Allow public read on instagram_accounts" ON public.instagram_accounts FOR SELECT USING (true);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'Allow authenticated all on instagram_accounts') THEN
        CREATE POLICY "Allow authenticated all on instagram_accounts" ON public.instagram_accounts FOR ALL USING (true);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'Allow public read on instagram_conversations') THEN
        CREATE POLICY "Allow public read on instagram_conversations" ON public.instagram_conversations FOR SELECT USING (true);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'Allow authenticated all on instagram_conversations') THEN
        CREATE POLICY "Allow authenticated all on instagram_conversations" ON public.instagram_conversations FOR ALL USING (true);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'Allow public read on instagram_messages') THEN
        CREATE POLICY "Allow public read on instagram_messages" ON public.instagram_messages FOR SELECT USING (true);
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE policyname = 'Allow authenticated all on instagram_messages') THEN
        CREATE POLICY "Allow authenticated all on instagram_messages" ON public.instagram_messages FOR ALL USING (true);
    END IF;
END $$;

DO $$
BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.instagram_conversations;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

DO $$
BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.instagram_messages;
EXCEPTION WHEN OTHERS THEN NULL;
END $$;
