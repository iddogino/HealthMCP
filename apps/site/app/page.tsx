import { ArrowDown, ArrowUpRight, Check, HeartPulse, KeyRound, LockKeyhole, Smartphone } from 'lucide-react';

export default function Home() {
  return <main>
    <section className="hero wrap">
      <div className="hero-copy">
        <p className="eyebrow"><span className="status-dot" /> PRIVATE HEALTH. PERSONAL AI.</p>
        <h1>Your health.<br />Your context.<br /><span>Your key.</span></h1>
        <p className="hero-description">Bring your Apple Health data to the AI tools you choose. Encrypted on your iPhone. Opened only with your private key.</p>
        <div className="hero-actions"><a className="cta" href="/connect">Connect your assistant <ArrowUpRight size={18} /></a><a className="text-link" href="#how-it-works">How it works <ArrowDown size={16} /></a></div>
        <p className="availability">Built for iPhone · V1 private beta</p>
      </div>
      <div className="hero-visual" aria-label="Health MCP iPhone app preview">
        <div className="orbit orbit-one" /><div className="orbit orbit-two" />
        <figure className="phone"><img src="/ios-overview.png" width="1206" height="2622" alt="Health MCP app showing a completed sync, encrypted cache, and sync history with illustrative data" /></figure>
        <div className="key-badge"><span className="key-badge-icon"><KeyRound size={22} /></span><div><strong>Only you hold the key.</strong><span>Health values stay encrypted in the cloud.</span></div></div>
        <p className="preview-note">Actual app. Illustrative sync data.</p>
      </div>
    </section>
    <div className="trust-strip"><div className="wrap"><span><Check size={16} /> Read-only Apple Health access</span><span><Check size={16} /> Encryption before upload</span><span><Check size={16} /> Revoke access anytime</span></div></div>
    <section id="how-it-works" className="how wrap">
      <div className="section-intro"><p className="eyebrow">A BRIDGE YOU CONTROL</p><h2>A little more connected.<br />A lot more yours.</h2><p>Your health history can give an assistant useful context. Health MCP lets you share it deliberately, with a key that the service never receives.</p></div>
      <div className="steps">
        {[{n:'01',icon:Smartphone,title:'Choose what to sync',body:'Connect Apple Health on your iPhone. Start your first backfill and follow its progress. Later syncs pick up what changed.'},{n:'02',icon:LockKeyhole,title:'Keep your key close',body:'Your phone encrypts every data file before it leaves. Save your private key somewhere safe. It cannot be recovered by the service.'},{n:'03',icon:HeartPulse,title:'Give your assistant context',body:'Pair a compatible MCP client, approve it on your phone, and configure your key in its private execution environment.'}].map(({n,icon:Icon,title,body})=><article key={n}><div className="step-top"><Icon size={25} strokeWidth={1.6}/><span>{n}</span></div><h3>{title}</h3><p>{body}</p></article>)}
      </div>
    </section>
    <section className="privacy-band"><div className="wrap privacy-inner"><div><p className="eyebrow">THE CLOUD STORES. YOU UNLOCK.</p><h2>Your data has a home.<br />Your key stays with you.</h2></div><div><p>The service stores encrypted files and a small catalog of available data. Your chosen assistant decrypts files in its own execution environment. Share your key only with a client you trust.</p><a className="text-link" href="/privacy">Read the privacy details <ArrowUpRight size={16}/></a></div></div></section>
  </main>;
}
