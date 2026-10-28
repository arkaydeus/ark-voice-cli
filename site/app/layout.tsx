import type { Metadata } from "next";
import { Geist_Mono, Space_Grotesk } from "next/font/google";
import { SiteHeader } from "@/components/site/site-header";
import { ThemeProvider } from "@/components/site/theme-provider";
import { TooltipProvider } from "@/components/ui/tooltip";
import { site } from "@/lib/site";
import "./globals.css";

const spaceGrotesk = Space_Grotesk({
  variable: "--font-space-grotesk",
  subsets: ["latin"],
});

const geistMono = Geist_Mono({
  variable: "--font-geist-mono",
  subsets: ["latin"],
});

export const metadata: Metadata = {
  title: {
    default: `${site.tagline} | ${site.name}`,
    template: `%s | ${site.name}`,
  },
  description: site.description,
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="en"
      suppressHydrationWarning
      className={`${spaceGrotesk.variable} ${geistMono.variable} antialiased`}
    >
      <body className="flex min-h-svh flex-col">
        <ThemeProvider
          attribute="class"
          defaultTheme="system"
          enableSystem
          disableTransitionOnChange
        >
          <TooltipProvider>
            <SiteHeader />
            {children}
          </TooltipProvider>
        </ThemeProvider>
      </body>
    </html>
  );
}
